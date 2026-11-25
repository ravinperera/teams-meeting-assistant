import Darwin
import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public let seq: Int
    public let timestamp: String
    public let source: String
    public let text: String
    public let speaker: String?

    public init(seq: Int, timestamp: String, source: String, text: String, speaker: String? = nil) {
        self.seq = seq
        self.timestamp = timestamp
        self.source = source
        self.text = text
        self.speaker = speaker
    }
}

public struct TranscriptSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public var active: Bool
    public let startedAt: String?
    public var updatedAt: String?
    public var segments: [TranscriptSegment]
    public var partials: [String: String]

    enum CodingKeys: String, CodingKey {
        case version, active, segments, partials
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }

    public init(active: Bool, startedAt: String?, updatedAt: String?, segments: [TranscriptSegment], partials: [String: String]) {
        self.version = 1
        self.active = active
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.segments = segments
        self.partials = partials
    }
}

public actor LiveTranscriptStore {
    public static let maximumSegments = 1_000
    public static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MeetingAssistant/live.json")

    private let url: URL
    private var snapshot: TranscriptSnapshot
    private var nextSequence = 1
    private var lastPartialWrite = Date.distantPast
    private let timestampFormatter = ISO8601DateFormatter()

    public init(url: URL = LiveTranscriptStore.defaultURL) {
        self.url = url
        self.snapshot = TranscriptSnapshot(active: false, startedAt: nil, updatedAt: nil, segments: [], partials: [:])
    }

    public func start() throws {
        let now = timestampFormatter.string(from: Date())
        snapshot = TranscriptSnapshot(active: true, startedAt: now, updatedAt: now, segments: [], partials: [:])
        nextSequence = 1
        try persist()
    }

    public func accept(text: String, source: String, isFinal: Bool) throws {
        guard snapshot.active else { return }
        guard source == "mic" || source == "system" else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            snapshot.partials[source] = nil
            if !trimmed.isEmpty {
                let timestamp = timestampFormatter.string(from: Date())
                snapshot.segments.append(TranscriptSegment(seq: nextSequence, timestamp: timestamp, source: source, text: trimmed))
                nextSequence += 1
                if snapshot.segments.count > Self.maximumSegments {
                    snapshot.segments.removeFirst(snapshot.segments.count - Self.maximumSegments)
                }
            }
            try persist()
        } else {
            snapshot.partials[source] = trimmed.isEmpty ? nil : trimmed
            if Date().timeIntervalSince(lastPartialWrite) >= 0.25 {
                try persist()
                lastPartialWrite = Date()
            }
        }
    }

    public func stop() throws {
        snapshot.active = false
        snapshot.partials = [:]
        try persist()
    }

    public func heartbeat() throws {
        guard snapshot.active else { return }
        try persist()
    }

    public func current() -> TranscriptSnapshot { snapshot }

    private func persist() throws {
        snapshot.updatedAt = timestampFormatter.string(from: Date())
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(snapshot)
        let temporary = directory.appendingPathComponent(".live-\(UUID().uuidString).tmp")
        var descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            try? FileManager.default.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw posixError() }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else { throw posixError() }
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
