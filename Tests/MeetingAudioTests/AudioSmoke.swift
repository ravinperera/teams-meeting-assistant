import AVFoundation

// Run without accessing real audio devices:
// swiftc -target arm64-apple-macosx26.0 -swift-version 6 \
//   Sources/MeetingAudio/MeetingAudioCapture.swift \
//   Tests/MeetingAudioTests/AudioSmoke.swift -o /tmp/meeting-audio-smoke
// /tmp/meeting-audio-smoke
@main
@MainActor
struct AudioSmoke {
    static func main() async {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ), let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
        else { fatalError("Could not allocate synthetic PCM") }

        source.frameLength = 4
        source.floatChannelData![0][0] = 0.25
        source.floatChannelData![1][0] = -0.5

        guard let copy = MeetingAudioBuffers.ownedCopy(of: source) else {
            fatalError("Could not copy synthetic PCM")
        }
        source.floatChannelData![0][0] = 1.0
        source.floatChannelData![1][0] = 1.0

        precondition(copy.frameLength == 4)
        precondition(copy.floatChannelData![0][0] == 0.25)
        precondition(copy.floatChannelData![1][0] == -0.5)

        guard let interleavedFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ), let interleaved = AVAudioPCMBuffer(pcmFormat: interleavedFormat, frameCapacity: 2)
        else { fatalError("Could not allocate interleaved PCM") }
        interleaved.frameLength = 2
        let samples = interleaved.audioBufferList.pointee.mBuffers.mData!
            .bindMemory(to: Float.self, capacity: 4)
        samples[0] = 0.75
        samples[1] = -0.25
        guard let interleavedCopy = MeetingAudioBuffers.ownedCopy(of: interleaved) else {
            fatalError("Could not copy interleaved PCM")
        }
        samples[0] = 0
        let copiedSamples = interleavedCopy.audioBufferList.pointee.mBuffers.mData!
            .bindMemory(to: Float.self, capacity: 4)
        precondition(copiedSamples[0] == 0.75)
        precondition(copiedSamples[1] == -0.25)

        let capture = MeetingAudioCapture()
        precondition(!capture.isRunning)
        await capture.stop()
        precondition(!capture.isRunning)
        print("MeetingAudio smoke passed (no devices accessed)")
    }
}
