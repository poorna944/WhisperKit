//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import AVFoundation
import CoreML
import Foundation
import Hub
import Tokenizers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Extensions

extension MLMultiArray {
    /// Calculate the linear offset by summing the products of each dimension’s index with the dimension’s stride.
    /// More info [here](https://developer.apple.com/documentation/coreml/mlmultiarray/2879231-subscript)
    /// - Parameters:
    ///  - index: The index of the element
    ///  - strides: The precomputed strides of the multi-array, if not provided, it will be computed. It's a performance optimization to avoid recomputing the strides every time when accessing the multi-array with multiple indexes.
    @inline(__always)
    func linearOffset(for index: [NSNumber], strides strideInts: [Int]? = nil) -> Int {
        var linearOffset = 0
        let strideInts = strideInts ?? strides.map { $0.intValue }
        for (dimension, stride) in zip(index, strideInts) {
            linearOffset += dimension.intValue * stride
        }
        return linearOffset
    }

    func fillLastDimension(indexes: Range<Int>, with value: FloatType) {
        precondition(shape.count == 3 && shape[0] == 1 && shape[1] == 1, "Must have [1, 1, n] shape")
        withUnsafeMutableBufferPointer(ofType: FloatType.self) { ptr, strides in
            for index in indexes {
                ptr[index * strides[2]] = value
            }
        }
    }

    func fill<Value>(indexes: [[NSNumber]], with value: Value) {
        let pointer = UnsafeMutablePointer<Value>(OpaquePointer(dataPointer))
        let strideInts = strides.map { $0.intValue }
        for index in indexes {
            let linearOffset = linearOffset(for: index, strides: strideInts)
            pointer[linearOffset] = value
        }
    }
}

extension MLModel {
    func asyncPrediction(
        from input: MLFeatureProvider,
        options: MLPredictionOptions
    ) async throws -> MLFeatureProvider {
        if #available(macOS 14, iOS 17, watchOS 10, visionOS 1, *) {
            return try await prediction(from: input, options: options)
        } else {
            return try await Task {
                try prediction(from: input, options: options)
            }.value
        }
    }
}

#if os(macOS)
// From: https://stackoverflow.com/a/71726663
extension Process {
    static func stringFromTerminal(command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", "sysctl -n " + command]
        task.launch()
        return String(bytes: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
    }

    static let processor = stringFromTerminal(command: "machdep.cpu.brand_string")
    static let cores = stringFromTerminal(command: "machdep.cpu.core_count")
    static let threads = stringFromTerminal(command: "machdep.cpu.thread_count")
    static let vendor = stringFromTerminal(command: "machdep.cpu.vendor")
    static let family = stringFromTerminal(command: "machdep.cpu.family")
}
#endif

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
public extension WhisperKit {
    static var isRunningOnSimulator: Bool {
#if targetEnvironment(simulator)
        return true
#else
        return false
#endif
    }
}


extension Float {
    func rounded(_ decimalPlaces: Int) -> Float {
        let divisor = pow(10.0, Float(decimalPlaces))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - Helpers

@available(macOS 13, iOS 16, watchOS 10, visionOS 1, *)
func initMLMultiArray(shape: [NSNumber], dataType: MLMultiArrayDataType, initialValue: Any) -> MLMultiArray {
    let multiArray = try! MLMultiArray(shape: shape, dataType: dataType)

    let count = multiArray.count
    let pointer = multiArray.dataPointer
    switch dataType {
        case .double:
            if let value = initialValue as? Double {
                let typedPointer = pointer.bindMemory(to: Double.self, capacity: count)
                typedPointer.initialize(repeating: value, count: count)
            }
        case .float32:
            if let value = initialValue as? Float {
                let typedPointer = pointer.bindMemory(to: Float.self, capacity: count)
                typedPointer.initialize(repeating: value, count: count)
            }
        case .float16:
            if let value = initialValue as? FloatType {
                let typedPointer = pointer.bindMemory(to: FloatType.self, capacity: count)
                typedPointer.initialize(repeating: value, count: count)
            }
        case .int32:
            if let value = initialValue as? Int32 {
                let typedPointer = pointer.bindMemory(to: Int32.self, capacity: count)
                typedPointer.initialize(repeating: value, count: count)
            }
        @unknown default:
            fatalError("Unsupported data type")
    }

    return multiArray
}

func getModelInputDimention(_ model: MLModel?, named: String, position: Int) -> Int? {
    guard let inputDescription = model?.modelDescription.inputDescriptionsByName[named] else { return nil }
    guard inputDescription.type == .multiArray else { return nil }
    guard let shapeConstraint = inputDescription.multiArrayConstraint else { return nil }
    let shape = shapeConstraint.shape.map { $0.intValue }
    return shape[position]
}

func getModelOutputDimention(_ model: MLModel?, named: String, position: Int) -> Int? {
    guard let inputDescription = model?.modelDescription.outputDescriptionsByName[named] else { return nil }
    guard inputDescription.type == .multiArray else { return nil }
    guard let shapeConstraint = inputDescription.multiArrayConstraint else { return nil }
    let shape = shapeConstraint.shape.map { $0.intValue }
    return shape[position]
}

func tokenizerNameForVariant(_ variant: ModelVariant) -> String {
    var tokenizerName: String
    switch variant {
        case .tiny:
            tokenizerName = "openai/whisper-tiny"
        case .tinyEn:
            tokenizerName = "openai/whisper-tiny.en"
        case .base:
            tokenizerName = "openai/whisper-base"
        case .baseEn:
            tokenizerName = "openai/whisper-base.en"
        case .small:
            tokenizerName = "openai/whisper-small"
        case .smallEn:
            tokenizerName = "openai/whisper-small.en"
        case .medium:
            tokenizerName = "openai/whisper-medium"
        case .mediumEn:
            tokenizerName = "openai/whisper-medium.en"
        case .large:
            tokenizerName = "openai/whisper-large"
        case .largev2:
            tokenizerName = "openai/whisper-large-v2"
        case .largev3:
            tokenizerName = "openai/whisper-large-v3"
    }

    return tokenizerName
}

func isModelMultilingual(logitsDim: Int?) -> Bool {
    logitsDim != 51864
}

func detectVariant(logitsDim: Int, encoderDim: Int) -> ModelVariant {
    // Defaults
    var modelVariant: ModelVariant = .base

    // Determine model size
    if logitsDim == 51865 {
        // Muiltilingual
        switch encoderDim {
            case 384:
                modelVariant = .tiny
            case 512:
                modelVariant = .base
            case 768:
                modelVariant = .small
            case 1024:
                modelVariant = .medium
            case 1280:
                modelVariant = .largev2 // same for v1
            default:
                modelVariant = .base
        }
    } else if logitsDim == 51864 {
        // English only
        switch encoderDim {
            case 384:
                modelVariant = .tinyEn
            case 512:
                modelVariant = .baseEn
            case 768:
                modelVariant = .smallEn
            case 1024:
                modelVariant = .mediumEn
            default:
                modelVariant = .baseEn
        }

    } else if logitsDim == 51866 {
        // Large v3 has 1 additional language token
        modelVariant = .largev3
    } else {
        Logging.error("Unrecognized vocabulary size: \(logitsDim), defaulting to base variant")
        modelVariant = .base
    }

    return modelVariant
}

public func modelSupport(for deviceName: String) -> (default: String, disabled: [String]) {
    switch deviceName {
        case let model where model.hasPrefix("iPhone11"), // A12
             let model where model.hasPrefix("iPhone12"), // A13
             let model where model.hasPrefix("Watch7"): // Series 9 and Ultra 2
            return ("openai_whisper-base", ["openai_whisper-small",
                                            "openai_whisper-small.en",
                                            "openai_whisper-large-v2",
                                            "openai_whisper-large-v2_949MB",
                                            "openai_whisper-large-v2_turbo",
                                            "openai_whisper-large-v2_turbo_955MB",
                                            "openai_whisper-large-v3",
                                            "openai_whisper-large-v3_947MB",
                                            "openai_whisper-large-v3_turbo",
                                            "openai_whisper-large-v3_turbo_954MB",
                                            "distil-whisper_distil-large-v3",
                                            "distil-whisper_distil-large-v3_594MB",
                                            "distil-whisper_distil-large-v3_turbo_600MB",
                                            "distil-whisper_distil-large-v3_turbo"])

        case let model where model.hasPrefix("iPhone13"): // A14
            return ("openai_whisper-base", ["openai_whisper-large-v2",
                                            "openai_whisper-large-v2_turbo",
                                            "openai_whisper-large-v2_turbo_955MB",
                                            "openai_whisper-large-v3",
                                            "openai_whisper-large-v3_turbo",
                                            "openai_whisper-large-v3_turbo_954MB",
                                            "distil-whisper_distil-large-v3_turbo_600MB",
                                            "distil-whisper_distil-large-v3_turbo"])

        case let model where model.hasPrefix("iPhone14"), // A15
             let model where model.hasPrefix("iPhone15"), // A16
             let model where model.hasPrefix("iPhone16"): // A17
            return ("openai_whisper-base", ["openai_whisper-large-v2",
                                            "openai_whisper-large-v2_turbo",
                                            "openai_whisper-large-v3",
                                            "openai_whisper-large-v3_turbo"])

        // Fall through to macOS checks
        default:
            break
    }

    #if os(macOS)
    if deviceName.hasPrefix("arm64") {
        if Process.processor.contains("Apple M1") {
            // Disable turbo variants for M1
            return ("openai_whisper-base", ["openai_whisper-large-v2_turbo",
                                            "openai_whisper-large-v2_turbo_955MB",
                                            "openai_whisper-large-v3_turbo",
                                            "openai_whisper-large-v3_turbo_954MB",
                                            "distil-whisper_distil-large-v3_turbo_600MB",
                                            "distil-whisper_distil-large-v3_turbo"])
        } else {
            // Enable all variants for M2 or M3, none disabled
            return ("openai_whisper-base", [])
        }
    }
    #endif

    // Unhandled device, default to base variant
    return ("openai_whisper-base", [""])
}

public func resolveAbsolutePath(_ inputPath: String) -> String {
    let fileManager = FileManager.default

    // Expanding tilde if present
    let pathWithTildeExpanded = NSString(string: inputPath).expandingTildeInPath

    // If the path is already absolute, return it
    if pathWithTildeExpanded.hasPrefix("/") {
        return pathWithTildeExpanded
    }

    // Resolving relative path based on the current working directory
    if let cwd = fileManager.currentDirectoryPath as String? {
        let resolvedPath = URL(fileURLWithPath: cwd).appendingPathComponent(pathWithTildeExpanded).path
        return resolvedPath
    }

    return inputPath
}

func loadTokenizer(
    for pretrained: ModelVariant,
    tokenizerFolder: URL? = nil,
    useBackgroundSession: Bool = false
) async throws -> WhisperTokenizer {
    let tokenizerName = tokenizerNameForVariant(pretrained)
    let hubApi = HubApi(downloadBase: tokenizerFolder, useBackgroundSession: useBackgroundSession)
    return try await WhisperTokenizerWrapper(
        tokenizer: AutoTokenizer.from(
            pretrained: tokenizerName,
            hubApi: hubApi
        )
    )
}

func formatTimestamp(_ timestamp: Float) -> String {
    return String(format: "%.2f", timestamp)
}

func formatTimeWithPercentage(_ time: Double, _ runs: Double, _ fullPipelineDuration: Double) -> String {
    let percentage = (time * 1000 / fullPipelineDuration) * 100 // Convert to percentage
    let runTime = runs > 0 ? time * 1000 / Double(runs) : 0
    let formattedString = String(format: "%8.2f ms / %6.0f runs (%8.2f ms/run) %5.2f%%", time * 1000, runs, runTime, percentage)
    return formattedString
}

public func formatSegments(_ segments: [TranscriptionSegment], withTimestamps: Bool = true) -> [String] {
    var lines = [String]()
    for segment in segments {
        let start = segment.start
        let end = segment.end
        let text = segment.text
        let timestamps = withTimestamps ? "[\(formatTimestamp(start)) --> \(formatTimestamp(end))] " : ""
        let line = "\(timestamps)\(text)"
        lines.append(line)
    }
    return lines
}

public func findLongestCommonPrefix(_ words1: [WordTiming], _ words2: [WordTiming]) -> [WordTiming] {
    let commonPrefix = zip(words1, words2).prefix(while: { $0.word == $1.word })
    return commonPrefix.map { $0.1 }
}

public func findLongestDifferentSuffix(_ words1: [WordTiming], _ words2: [WordTiming]) -> [WordTiming] {
    let commonPrefix = findLongestCommonPrefix(words1, words2)
    let remainingWords = words2[commonPrefix.count...]
    return Array(remainingWords)
}

public func mergeTranscriptionResults(_ results: [TranscriptionResult?], confirmedWords: [WordTiming]) -> TranscriptionResult {
    let validResults = results.compactMap { $0 }
    let language = validResults.first?.language ?? "en"

    var mergedSegments: [TranscriptionSegment] = []
    let mergedText = confirmedWords.map { $0.word }.joined()

    for result in validResults {
        mergedSegments.append(contentsOf: result.segments)
    }

    var mergedTimings = TranscriptionTimings(
        modelLoading: validResults.map { $0.timings?.modelLoading ?? 0 }.max() ?? 0,
        audioLoading: validResults.map { $0.timings?.audioLoading ?? 0 }.reduce(0, +),
        audioProcessing: validResults.map { $0.timings?.audioProcessing ?? 0 }.reduce(0, +),
        logmels: validResults.map { $0.timings?.logmels ?? 0 }.reduce(0, +),
        encoding: validResults.map { $0.timings?.encoding ?? 0 }.reduce(0, +),
        prefill: validResults.map { $0.timings?.prefill ?? 0 }.reduce(0, +),
        decodingInit: validResults.map { $0.timings?.decodingInit ?? 0 }.reduce(0, +),
        decodingLoop: validResults.map { $0.timings?.decodingLoop ?? 0 }.reduce(0, +),
        decodingPredictions: validResults.map { $0.timings?.decodingPredictions ?? 0 }.reduce(0, +),
        decodingFiltering: validResults.map { $0.timings?.decodingFiltering ?? 0 }.reduce(0, +),
        decodingSampling: validResults.map { $0.timings?.decodingSampling ?? 0 }.reduce(0, +),
        decodingFallback: validResults.map { $0.timings?.decodingFallback ?? 0 }.reduce(0, +),
        decodingWindowing: validResults.map { $0.timings?.decodingWindowing ?? 0 }.reduce(0, +),
        decodingKvCaching: validResults.map { $0.timings?.decodingKvCaching ?? 0 }.reduce(0, +),
        decodingTimestampAlignment: validResults.map { $0.timings?.decodingWordTimestamps ?? 0 }.reduce(0, +),
        decodingNonPrediction: validResults.map { $0.timings?.decodingNonPrediction ?? 0 }.reduce(0, +),
        totalAudioProcessingRuns: validResults.map { $0.timings?.totalAudioProcessingRuns ?? 0 }.reduce(0, +),
        totalLogmelRuns: validResults.map { $0.timings?.totalLogmelRuns ?? 0 }.reduce(0, +),
        totalEncodingRuns: validResults.map { $0.timings?.totalEncodingRuns ?? 0 }.reduce(0, +),
        totalDecodingLoops: validResults.map { $0.timings?.totalDecodingLoops ?? 0 }.reduce(0, +),
        totalKVUpdateRuns: validResults.map { $0.timings?.totalKVUpdateRuns ?? 0 }.reduce(0, +),
        totalTimestampAlignmentRuns: validResults.map { $0.timings?.totalTimestampAlignmentRuns ?? 0 }.reduce(0, +),
        totalDecodingFallbacks: validResults.map { $0.timings?.totalDecodingFallbacks ?? 0 }.reduce(0, +),
        totalDecodingWindows: validResults.map { $0.timings?.totalDecodingWindows ?? 0 }.reduce(0, +),
        fullPipeline: validResults.map { $0.timings?.fullPipeline ?? 0 }.reduce(0, +)
    )

    mergedTimings.inputAudioSeconds = validResults.map { $0.timings?.inputAudioSeconds ?? 0 }.reduce(0, +)

    // Average first token times
    if let pipelineStart = validResults.first?.timings?.pipelineStart {
        let averageFirstTokenTime = validResults.map { (($0.timings?.firstTokenTime ?? 0) - ($0.timings?.pipelineStart ?? 0)) }.reduce(0, +) / Double(validResults.count)
        mergedTimings.pipelineStart = pipelineStart
        mergedTimings.firstTokenTime = pipelineStart + averageFirstTokenTime
    }

    return TranscriptionResult(
        text: mergedText,
        segments: mergedSegments,
        language: language,
        timings: mergedTimings
    )
}

func timeit(operation: () -> Void) -> TimeInterval {
    let startTime = CFAbsoluteTimeGetCurrent()
    operation()
    let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
    return TimeInterval(timeElapsed)
}

func getDownloadsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
    return paths[0]
}

func saveBuffer(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
    // create folder
    let folderURL = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: folderURL.path) {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
    }
    let audioFile = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
    try audioFile.write(from: buffer)
}

func rescale(value: Float, min: Float, max: Float) -> Float {
    return (value - min) / (max - min)
}

public func compressionRatio(of array: [Int]) -> Float {
    // Convert the integer array to a byte array (Data)
    let dataBuffer = array.compactMap { Int32($0) }
    let data = dataBuffer.withUnsafeBufferPointer { Data(buffer: $0) }

    // Compress the data using NSData compression
    do {
        let compressedData = try (data as NSData).compressed(using: .zlib)
        // Calculate and return the compression ratio
        return Float(data.count) / Float(compressedData.length)
    } catch {
        Logging.debug("Compression error: \(error.localizedDescription)")
        return Float.infinity
    }
}

public func compressionRatio(of text: String) -> Float {
    if text.isEmpty {
        return Float.infinity // TODO: throw to caller instead of return infinity
    }

    // Encode the string as UTF-8
    guard let data = text.data(using: .utf8) else {
        Logging.debug("String encoding error")
        return Float.infinity
    }

    // Compress the data using NSData compression
    do {
        let compressedData = try (data as NSData).compressed(using: .zlib)
        // Calculate and return the compression ratio
        return Float(data.count) / Float(compressedData.length)
    } catch {
        Logging.debug("Compression error: \(error.localizedDescription)")
        return Float.infinity
    }
}

// MARK: - Singletons

public class Logging {
    static let shared = Logging()
    var logLevel: LogLevel = .none

    public typealias LoggingCallback = (_ message: String) -> Void
    var loggingCallback: LoggingCallback?

    public enum LogLevel: Int {
        case debug = 1
        case info = 2
        case error = 3
        case none = 4

        func shouldLog(level: LogLevel) -> Bool {
            return self.rawValue <= level.rawValue
        }
    }

    private init() {}

    public func log(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        let message = items.map { "\($0)" }.joined(separator: separator)
        if let logger = loggingCallback {
            logger(message)
        } else {
            print("[WhisperKit] \(message)", terminator: terminator)
        }
    }

    public static func debug(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        if shared.logLevel.shouldLog(level: .debug) {
            shared.log(items, separator: separator, terminator: terminator)
        }
    }

    public static func info(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        if shared.logLevel.shouldLog(level: .info) {
            shared.log(items, separator: separator, terminator: terminator)
        }
    }

    public static func error(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        if shared.logLevel.shouldLog(level: .error) {
            shared.log(items, separator: separator, terminator: terminator)
        }
    }
}
