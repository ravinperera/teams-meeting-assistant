import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum TranscriptSource: String, CaseIterable, Sendable {
    case system
    case microphone
}

/// A single revision of a speech segment. A partial result may be replaced by a later
/// result with the same audio range; finalized results will not change.
public struct TranscriptEvent: Sendable {
    public let source: TranscriptSource
    public let text: String
    public let isFinal: Bool
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(
        source: TranscriptSource,
        text: String,
        isFinal: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.startTime = startTime
        self.endTime = endTime
    }
}

public enum LiveTranscriberError: Error, LocalizedError, Sendable {
    case alreadyStarted
    case notRunning
    case unavailable
    case unsupportedLocale(String)
    case audioFormatUnavailable
    case audioConversionUnsupported
    case audioConversionStalled
    case inputBacklogExceeded

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "Transcription is already running."
        case .notRunning: "Transcription has not started."
        case .unavailable: "On-device speech transcription is unavailable on this Mac."
        case .unsupportedLocale(let identifier): "Speech transcription does not support \(identifier)."
        case .audioFormatUnavailable: "No compatible on-device speech audio format is available."
        case .audioConversionUnsupported: "The incoming audio format cannot be converted for speech recognition."
        case .audioConversionStalled: "The audio converter stopped making progress."
        case .inputBacklogExceeded: "Speech processing fell behind the live audio stream."
        }
    }
}

/// One instance transcribes one ordered PCM stream, such as meeting audio or the microphone.
/// The supplied buffers stay in memory and are never saved by this module.
@available(macOS 26.0, *)
public actor LiveTranscriber {
    public let source: TranscriptSource
    public let locale: Locale

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var outputContinuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: PCMInputConverter?
    private var started = false

    public init(source: TranscriptSource, locale: Locale = Locale(identifier: "en_GB")) {
        self.source = source
        self.locale = locale
    }

    /// Installs an Apple speech model if required, then starts streaming partial and final results.
    /// Call once per instance and consume the returned stream while feeding audio with `append`.
    public func start() async throws -> AsyncThrowingStream<TranscriptEvent, Error> {
        guard !started else { throw LiveTranscriberError.alreadyStarted }
        started = true
        defer {
            if analyzer == nil { started = false }
        }
        guard SpeechTranscriber.isAvailable else { throw LiveTranscriberError.unavailable }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LiveTranscriberError.unsupportedLocale(locale.identifier)
        }

        let transcriber = SpeechTranscriber(locale: supportedLocale, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTranscriberError.audioFormatUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: audioFormat)

        // Keep a bounded backlog. A full queue is reported as an error instead of silently
        // dropping speech from a meeting that the user expects to be transcribed.
        let (inputs, inputContinuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingOldest(512)
        )
        let (events, outputContinuation) = AsyncThrowingStream<TranscriptEvent, Error>.makeStream()
        let source = self.source
        let resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    outputContinuation.yield(TranscriptEvent(
                        source: source,
                        text: text,
                        isFinal: result.isFinal,
                        startTime: CMTimeGetSeconds(result.range.start),
                        endTime: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
                    ))
                }
                outputContinuation.finish()
            } catch {
                outputContinuation.finish(throwing: error)
            }
        }

        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            inputContinuation.finish()
            resultsTask.cancel()
            await analyzer.cancelAndFinishNow()
            outputContinuation.finish(throwing: error)
            throw error
        }

        self.analyzer = analyzer
        self.inputContinuation = inputContinuation
        self.outputContinuation = outputContinuation
        self.resultsTask = resultsTask
        self.converter = PCMInputConverter(outputFormat: audioFormat)
        self.started = true
        return events
    }

    /// Appends one PCM buffer in source order. `audioTime` is accepted from the capture
    /// callback; the analyzer uses a continuous, stream-relative clock for each source.
    public func append(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime? = nil) async throws {
        guard started, let inputContinuation, var converter else {
            throw LiveTranscriberError.notRunning
        }
        _ = audioTime
        let convertedBuffers = try converter.convert(buffer)
        self.converter = converter
        for convertedBuffer in convertedBuffers {
            switch inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer)) {
            case .enqueued:
                break
            case .dropped:
                await cancel(throwing: LiveTranscriberError.inputBacklogExceeded)
                throw LiveTranscriberError.inputBacklogExceeded
            case .terminated:
                throw LiveTranscriberError.notRunning
            @unknown default:
                throw LiveTranscriberError.notRunning
            }
        }
    }

    /// Drains any pending converter samples and finalizes the last spoken segment.
    public func finish() async throws {
        guard started, let analyzer, let inputContinuation else { return }
        if var converter {
            for buffer in try converter.flush() {
                switch inputContinuation.yield(AnalyzerInput(buffer: buffer)) {
                case .enqueued:
                    break
                case .dropped:
                    await cancel(throwing: LiveTranscriberError.inputBacklogExceeded)
                    throw LiveTranscriberError.inputBacklogExceeded
                case .terminated:
                    break
                @unknown default:
                    break
                }
            }
            self.converter = converter
        }
        inputContinuation.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            outputContinuation?.finish(throwing: error)
            await cancel(throwing: error)
            throw error
        }
        await resultsTask?.value
        clearState()
    }

    private func cancel(throwing error: Error) async {
        inputContinuation?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
        outputContinuation?.finish(throwing: error)
        clearState()
    }

    private func clearState() {
        analyzer = nil
        inputContinuation = nil
        outputContinuation = nil
        resultsTask = nil
        converter = nil
        started = false
    }
}

/// AVAudioConverter is required on macOS 26: Speech's AnalyzerInputConverter arrives in macOS 27.
@available(macOS 26.0, *)
package struct PCMInputConverter {
    let outputFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat?
    private var audioConverter: AVAudioConverter?

    package init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    package mutating func convert(_ buffer: AVAudioPCMBuffer) throws -> [AVAudioPCMBuffer] {
        guard buffer.frameLength > 0 else { return [] }
        if buffer.format.isEqual(outputFormat) {
            // Audio capture callbacks are allowed to reuse their original storage.
            return [buffer.copy() as! AVAudioPCMBuffer]
        }
        if inputFormat?.isEqual(buffer.format) != true {
            guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
                throw LiveTranscriberError.audioConversionUnsupported
            }
            audioConverter = converter
            inputFormat = buffer.format
        }
        guard let audioConverter else { throw LiveTranscriberError.audioConversionUnsupported }

        var suppliedInput = false
        return try produce(using: audioConverter, inputFrameCount: buffer.frameLength) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return buffer
        }
    }

    package mutating func flush() throws -> [AVAudioPCMBuffer] {
        guard let audioConverter else { return [] }
        let buffers = try produce(using: audioConverter, inputFrameCount: 1024) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        self.audioConverter = nil
        inputFormat = nil
        return buffers
    }

    private func produce(
        using converter: AVAudioConverter,
        inputFrameCount: AVAudioFrameCount,
        input: @escaping AVAudioConverterInputBlock
    ) throws -> [AVAudioPCMBuffer] {
        let inputRate = max(converter.inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount(max(1024, ceil(Double(inputFrameCount) * outputFormat.sampleRate / inputRate) + 64))
        var buffers: [AVAudioPCMBuffer] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw LiveTranscriberError.audioConversionUnsupported
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError, withInputFrom: input)
            if let conversionError { throw conversionError }
            if output.frameLength > 0 { buffers.append(output) }
            switch status {
            case .haveData:
                guard output.frameLength > 0 else { throw LiveTranscriberError.audioConversionStalled }
            case .inputRanDry, .endOfStream:
                return buffers
            case .error:
                throw LiveTranscriberError.audioConversionUnsupported
            @unknown default:
                throw LiveTranscriberError.audioConversionUnsupported
            }
        }
    }
}
