import AVFoundation
import Darwin
import Dispatch
import Foundation
import MeetingAudio
import MeetingSpeech
import MeetingTranscript

private struct AudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime
}

private actor ShutdownLatch {
    private var didStop = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if didStop { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func stop() {
        didStop = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class SessionLock {
    private var descriptor: Int32 = -1

    init() throws {
        let directory = LiveTranscriptStore.defaultURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("session.lock").path
        let opened = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard opened >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard Darwin.lockf(opened, F_TLOCK, 0) == 0 else {
            let code = errno
            _ = Darwin.close(opened)
            if code == EAGAIN || code == EACCES {
                throw SessionLockError.alreadyRunning
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        descriptor = opened
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }
}

private enum SessionLockError: LocalizedError {
    case alreadyRunning
    var errorDescription: String? {
        "Meeting Assistant is already running. Stop the existing session before starting another."
    }
}

@main
private struct MeetingAssistantCLI {
    static func main() async {
        do {
            switch CommandLine.arguments.dropFirst().first ?? "help" {
            case "start":
                try await start(locale: try startLocale())
            case "status":
                try status()
            case "help", "--help", "-h":
                usage()
            default:
                usage()
                Darwin.exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("Meeting assistant: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func usage() {
        print("Usage: meeting-assistant start [--locale <language-tag>] | status")
        print("  start    Capture Teams audio and your microphone locally until Ctrl+C")
        print("           Default language: en-GB (example: --locale fr-FR)")
        print("  status   Show whether the local companion is active")
    }

    private static func startLocale() throws -> Locale {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        if arguments.isEmpty { return Locale(identifier: "en_GB") }
        guard arguments.count == 2,
              arguments[0] == "--locale",
              !arguments[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CLIError.invalidStartOptions }
        return Locale(identifier: arguments[1].replacingOccurrences(of: "-", with: "_"))
    }

    private static func status() throws {
        let url = LiveTranscriptStore.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("No meeting assistant session has started.")
            return
        }
        let snapshot = try JSONDecoder().decode(TranscriptSnapshot.self, from: Data(contentsOf: url))
        let lastUpdate = snapshot.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let stale = snapshot.active && (lastUpdate.map { Date().timeIntervalSince($0) > 20 } ?? true)
        print(stale ? "Meeting assistant appears stopped (stale heartbeat)." : (snapshot.active ? "Meeting assistant is active." : "Meeting assistant is stopped."))
        print("Final transcript segments: \(snapshot.segments.count)")
        if let updated = snapshot.updatedAt { print("Last update: \(updated)") }
    }

    @MainActor
    private static func start(locale: Locale) async throws {
        let sessionLock = try SessionLock()
        defer { sessionLock.release() }
        let store = LiveTranscriptStore()
        let shutdown = ShutdownLatch()
        let systemTranscriber = LiveTranscriber(source: .system, locale: locale)
        let micTranscriber = LiveTranscriber(source: .microphone, locale: locale)
        print("Preparing on-device speech models...")
        let systemResults = try await systemTranscriber.start()
        let micResults: AsyncThrowingStream<TranscriptEvent, Error>
        do {
            micResults = try await micTranscriber.start()
        } catch {
            try? await systemTranscriber.finish()
            throw error
        }

        let systemPackets = AsyncStream<AudioPacket>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let micPackets = AsyncStream<AudioPacket>.makeStream(bufferingPolicy: .bufferingOldest(512))

        let systemFeed = Task {
            do {
                for await packet in systemPackets.stream {
                    try await systemTranscriber.append(packet.buffer, at: packet.time)
                }
            } catch {
                report(error)
                await shutdown.stop()
            }
        }
        let micFeed = Task {
            do {
                for await packet in micPackets.stream {
                    try await micTranscriber.append(packet.buffer, at: packet.time)
                }
            } catch {
                report(error)
                await shutdown.stop()
            }
        }
        let systemRead = Task {
            do {
                for try await event in systemResults {
                    try await store.accept(text: event.text, source: "system", isFinal: event.isFinal)
                }
            } catch {
                report(error)
                await shutdown.stop()
            }
        }
        let micRead = Task {
            do {
                for try await event in micResults {
                    try await store.accept(text: event.text, source: "mic", isFinal: event.isFinal)
                }
            } catch {
                report(error)
                await shutdown.stop()
            }
        }

        let capture = MeetingAudioCapture()
        var captureError: Error?
        var started = false
        var snapshotStarted = false
        var heartbeat: Task<Void, Never>?
        do {
            try await capture.start(
                onSystemBuffer: { buffer, time in
                    if case .dropped = systemPackets.continuation.yield(AudioPacket(buffer: buffer, time: time)) {
                        reportBacklog("Teams audio")
                        Task { await shutdown.stop() }
                    }
                },
                onMicBuffer: { buffer, time in
                    if case .dropped = micPackets.continuation.yield(AudioPacket(buffer: buffer, time: time)) {
                        reportBacklog("microphone audio")
                        Task { await shutdown.stop() }
                    }
                }
            )
            started = true
            try await store.start()
            snapshotStarted = true
            heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { break }
                    try? await store.heartbeat()
                }
            }
            let signals = watchSignals(shutdown: shutdown)
            print("Listening to Teams audio and your microphone locally. Press Ctrl+C to stop.")
            await shutdown.wait()
            signals.forEach { $0.cancel() }
        } catch {
            captureError = error
        }

        if started { await capture.stop() }
        systemPackets.continuation.finish()
        micPackets.continuation.finish()
        await systemFeed.value
        await micFeed.value
        do { try await systemTranscriber.finish() } catch { report(error) }
        do { try await micTranscriber.finish() } catch { report(error) }
        await systemRead.value
        await micRead.value
        heartbeat?.cancel()
        await heartbeat?.value
        if snapshotStarted { try await store.stop() }
        if let captureError { throw captureError }
        print("Meeting assistant stopped. Local transcript retained at \(LiveTranscriptStore.defaultURL.path)")
    }

    private static func watchSignals(shutdown: ShutdownLatch) -> [any DispatchSourceSignal] {
        Darwin.signal(SIGINT, SIG_IGN)
        Darwin.signal(SIGTERM, SIG_IGN)
        return [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { Task { await shutdown.stop() } }
            source.resume()
            return source
        }
    }

    private static func report(_ error: Error) {
        FileHandle.standardError.write(Data("Meeting assistant audio error: \(error.localizedDescription)\n".utf8))
    }

    private static func reportBacklog(_ source: String) {
        FileHandle.standardError.write(Data("Meeting assistant: \(source) processing fell behind; stopping to avoid a silent transcript gap.\n".utf8))
    }
}

private enum CLIError: LocalizedError {
    case invalidStartOptions

    var errorDescription: String? {
        "Use start [--locale <language-tag>], for example start --locale en-GB."
    }
}
