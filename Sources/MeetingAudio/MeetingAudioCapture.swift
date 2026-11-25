import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// A PCM callback is called in sample order for its source.
/// The buffer owns its storage and is safe to retain after the callback returns.
public typealias MeetingAudioBufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

public enum MeetingAudioCaptureError: LocalizedError {
    case alreadyRunning
    case teamsNotRunning
    case microphonePermissionDenied
    case missingUsageDescription(String)
    case microphoneFormatUnavailable
    case systemAudioFormatUnavailable
    case startCancelled
    case coreAudio(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Meeting audio capture is already running."
        case .teamsNotRunning:
            "Microsoft Teams is not running. Open the meeting in Teams before starting capture."
        case .microphonePermissionDenied:
            "Microphone access is required. Allow this app in System Settings > Privacy & Security > Microphone."
        case let .missingUsageDescription(key):
            "The app bundle is missing \(key) in Info.plist, which macOS requires before audio capture."
        case .microphoneFormatUnavailable:
            "The selected microphone has no usable PCM format."
        case .systemAudioFormatUnavailable:
            "The Microsoft Teams audio tap has no usable PCM format."
        case .startCancelled:
            "Meeting audio capture was stopped before it could start."
        case let .coreAudio(operation, status):
            "Could not \(operation) (Core Audio status \(status)). Check System Settings > Privacy & Security > Screen & System Audio Recording and allow this app to record system audio."
        }
    }
}

/// Captures only Microsoft Teams output audio plus the local microphone.
/// Creating this object does not ask for permissions or start either source.
@MainActor
public final class MeetingAudioCapture {
    private var systemTap: TeamsProcessAudioTap?
    private var microphoneEngine: AVAudioEngine?
    private var deliveryGate: AudioDeliveryGate?
    private var starting = false
    private var startGeneration = 0

    public init() {}

    public var isRunning: Bool { systemTap != nil && microphoneEngine != nil }

    /// Starts both sources. Callbacks may run concurrently across sources, but are ordered
    /// within each source. The caller should enqueue work promptly to avoid audio dropouts.
    public func start(
        onSystemBuffer: @escaping MeetingAudioBufferHandler,
        onMicBuffer: @escaping MeetingAudioBufferHandler
    ) async throws {
        guard !isRunning, !starting else { throw MeetingAudioCaptureError.alreadyRunning }
        starting = true
        defer { starting = false }
        let generation = startGeneration

        let teamsBundleIDs = Self.runningTeamsBundleIDs()
        guard !teamsBundleIDs.isEmpty else { throw MeetingAudioCaptureError.teamsNotRunning }
        for key in ["NSAudioCaptureUsageDescription", "NSMicrophoneUsageDescription"] {
            guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw MeetingAudioCaptureError.missingUsageDescription(key) }
        }

        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            authorized = false
        }
        guard generation == startGeneration else { throw MeetingAudioCaptureError.startCancelled }
        guard authorized else { throw MeetingAudioCaptureError.microphonePermissionDenied }

        let gate = AudioDeliveryGate()
        let tap = TeamsProcessAudioTap(bundleIDs: teamsBundleIDs) { buffer, time in
            guard gate.isOpen else { return }
            onSystemBuffer(buffer, time)
        }

        do {
            try tap.start()

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MeetingAudioCaptureError.microphoneFormatUnavailable
            }

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
                guard gate.isOpen, let owned = MeetingAudioBuffers.ownedCopy(of: buffer) else { return }
                onMicBuffer(owned, time)
            }
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }

            deliveryGate = gate
            systemTap = tap
            microphoneEngine = engine
        } catch {
            gate.close()
            tap.stop()
            throw error
        }
    }

    public func stop() async {
        startGeneration &+= 1
        deliveryGate?.close()
        if let engine = microphoneEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        systemTap?.stop()
        microphoneEngine = nil
        systemTap = nil
        deliveryGate = nil
    }

    private static func runningTeamsBundleIDs() -> [String] {
        let roots = ["com.microsoft.teams2", "com.microsoft.teams"]
        let running = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .compactMap(\.bundleIdentifier)
        guard running.contains(where: { roots.contains($0) }) else { return [] }
        return Array(Set(running.filter { bundleID in
            roots.contains(bundleID) || roots.contains(where: { bundleID.hasPrefix($0 + ".") })
        })).sorted()
    }
}

private final class AudioDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool { lock.withLock { open } }
    func close() { lock.withLock { open = false } }
}

public enum MeetingAudioBuffers {
    /// Returns a PCM buffer with independent storage, suitable for asynchronous consumers.
    public static func ownedCopy(of source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        copy(source.audioBufferList, format: source.format, frameCount: source.frameLength)
    }

    static func copy(
        _ source: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        result.frameLength = frameCount

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard inputBuffers.count == outputBuffers.count else { return nil }

        for index in inputBuffers.indices {
            let input = inputBuffers[index]
            guard let inputData = input.mData,
                  let outputData = outputBuffers[index].mData,
                  input.mDataByteSize <= outputBuffers[index].mDataByteSize
            else { return nil }
            memcpy(outputData, inputData, Int(input.mDataByteSize))
            outputBuffers[index].mDataByteSize = input.mDataByteSize
        }
        return result
    }
}

/// A private aggregate device exposes a Teams-only process tap as an input stream.
private final class TeamsProcessAudioTap: @unchecked Sendable {
    private let bundleIDs: [String]
    private let onBuffer: MeetingAudioBufferHandler
    private let ioQueue = DispatchQueue(label: "MeetingAssistant.TeamsAudio")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var started = false

    init(bundleIDs: [String], onBuffer: @escaping MeetingAudioBufferHandler) {
        self.bundleIDs = bundleIDs
        self.onBuffer = onBuffer
    }

    func start() throws {
        let description = CATapDescription()
        description.name = "Meeting Assistant Microsoft Teams audio"
        description.bundleIDs = bundleIDs
        description.isPrivate = true
        description.isExclusive = false
        description.isMixdown = true
        description.isMono = false
        description.isProcessRestoreEnabled = true

        do {
            try check(AudioHardwareCreateProcessTap(description, &tapID), "create Microsoft Teams audio tap")
            let tapUID = try readTapUID()
            let bufferFormat = try readTapFormat()
            format = bufferFormat

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Meeting Assistant Teams input",
                kAudioAggregateDeviceUIDKey: "meeting-assistant.teams.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            ]
            try check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                "create private Microsoft Teams audio device"
            )

            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [onBuffer] _, inputData, inputTime, _, _ in
                    let byteCount = inputData.pointee.mBuffers.mDataByteSize
                    let bytesPerFrame = bufferFormat.streamDescription.pointee.mBytesPerFrame
                    guard bytesPerFrame > 0 else { return }
                    let frameCount = AVAudioFrameCount(byteCount / bytesPerFrame)
                    guard let owned = MeetingAudioBuffers.copy(inputData, format: bufferFormat, frameCount: frameCount) else { return }
                    let time = AVAudioTime(audioTimeStamp: inputTime, sampleRate: bufferFormat.sampleRate)
                    onBuffer(owned, time)
                },
                "register Microsoft Teams audio callback"
            )
            try check(AudioDeviceStart(aggregateID, ioProcID), "start Microsoft Teams audio capture")
            started = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if started { _ = AudioDeviceStop(aggregateID, ioProcID) }
        started = false
        if let ioProcID {
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        format = nil
    }

    private func readTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uidReference: Unmanaged<CFString>?
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &uidReference),
            "read Microsoft Teams audio tap identifier"
        )
        guard let uidReference else { throw MeetingAudioCaptureError.systemAudioFormatUnavailable }
        return uidReference.takeRetainedValue() as String
    }

    private func readTapFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            "read Microsoft Teams audio tap format"
        )
        guard let format = AVAudioFormat(streamDescription: &asbd),
              format.sampleRate > 0, format.channelCount > 0,
              asbd.mBytesPerFrame > 0
        else { throw MeetingAudioCaptureError.systemAudioFormatUnavailable }
        return format
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw MeetingAudioCaptureError.coreAudio(operation: operation, status: status)
        }
    }
}
