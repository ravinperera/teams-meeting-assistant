import AVFoundation
import Foundation
import MeetingSpeech

@available(macOS 26.0, *)
func runSpeechSmokeChecks() throws {
    guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
          let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
          let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800),
          let inputChannels = input.floatChannelData
    else { throw SpeechSmokeFailure("synthetic PCM setup") }

    input.frameLength = 4_800
    for frame in 0..<Int(input.frameLength) {
        let sample = Float(sin(2 * .pi * 440 * Double(frame) / 48_000))
        inputChannels[0][frame] = sample
        inputChannels[1][frame] = sample
    }

    var converter = PCMInputConverter(outputFormat: outputFormat)
    let converted = try converter.convert(input) + converter.flush()
    let convertedFrames = converted.reduce(0) { $0 + Int($1.frameLength) }
    try require(!converted.isEmpty, "PCM converter produced no buffers")
    try require(converted.allSatisfy { $0.format.isEqual(outputFormat) }, "PCM output format")
    try require((1_500..<1_700).contains(convertedFrames), "PCM resampling frame count")

    guard let compatible = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4),
          let compatibleSamples = compatible.floatChannelData
    else { throw SpeechSmokeFailure("compatible PCM setup") }
    compatible.frameLength = 4
    compatibleSamples[0][0] = 0.25
    var copyConverter = PCMInputConverter(outputFormat: outputFormat)
    guard let owned = try copyConverter.convert(compatible).first,
          let ownedSamples = owned.floatChannelData
    else { throw SpeechSmokeFailure("compatible PCM copy") }
    compatibleSamples[0][0] = 0.75
    try require(owned.frameLength == 4 && ownedSamples[0][0] == 0.25, "PCM copy owns its samples")
}

private func require(_ condition: Bool, _ label: String) throws {
    if !condition { throw SpeechSmokeFailure(label) }
}

private struct SpeechSmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = "Speech self-test failed: \(description)" }
}
