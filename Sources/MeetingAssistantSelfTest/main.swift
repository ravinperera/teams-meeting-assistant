import AVFoundation
import Foundation
import MeetingAudio
import MeetingSpeech
import MeetingTranscript

@main
private struct MeetingAssistantSelfTest {
    static func main() async throws {
        try await transcriptSnapshotTest()
        try audioBufferCopyTest()
        try runSpeechSmokeChecks()
        print("Meeting assistant self-tests passed.")
    }

    private static func transcriptSnapshotTest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("live.json")
        let store = LiveTranscriptStore(url: url)

        try await store.start()
        try await store.accept(text: "Checking the design", source: "mic", isFinal: false)
        let partial = try JSONDecoder().decode(TranscriptSnapshot.self, from: Data(contentsOf: url))
        try require(partial.active && partial.partials["mic"] == "Checking the design", "partial transcript")

        try await store.accept(text: "Checking the design", source: "mic", isFinal: true)
        try await store.accept(text: "Screen shows a VPC", source: "system", isFinal: true)
        try await store.stop()
        let final = try JSONDecoder().decode(TranscriptSnapshot.self, from: Data(contentsOf: url))
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        try require(directoryMode == 0o700 && fileMode == 0o600, "transcript file permissions")
        try require(!final.active && final.partials.isEmpty, "stopped snapshot")
        try require(final.segments.map(\.seq) == [1, 2], "sequence numbers")
        try require(final.segments.map(\.source) == ["mic", "system"], "audio sources")
        try require(final.segments.map(\.text) == ["Checking the design", "Screen shows a VPC"], "final transcript")
    }

    private static func audioBufferCopyTest() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let original = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8),
              let samples = original.floatChannelData?[0]
        else { throw TestFailure("synthetic PCM setup") }
        original.frameLength = 8
        samples[0] = 0.25
        guard let copy = MeetingAudioBuffers.ownedCopy(of: original),
              let copiedSamples = copy.floatChannelData?[0]
        else { throw TestFailure("PCM copy") }
        samples[0] = 0.75
        try require(copy.frameLength == 8 && copiedSamples[0] == 0.25, "PCM copy owns its storage")
    }

    private static func require(_ condition: Bool, _ label: String) throws {
        if !condition { throw TestFailure(label) }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "Self-test failed: \(description)" }
}
