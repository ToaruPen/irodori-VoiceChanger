import Foundation
import IrodoriVoiceChangerCore
import OnnxRuntimeBindings

public enum SmartTurnClassifierError: Error, Equatable, Sendable {
    case modelUnavailable
    case preprocessingFailed
    case inferenceFailed
    case invalidOutput
}

public actor SmartTurnClassifier: SemanticTurnClassifying {
    private let environment: ORTEnv
    private let session: ORTSession

    public init(modelURL: URL? = nil) throws {
        let resolvedURL: URL
        if let modelURL {
            resolvedURL = modelURL
        } else if let packaged = Self.packagedModelURL() {
            resolvedURL = packaged
        } else {
            throw SmartTurnClassifierError.modelUnavailable
        }
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            throw SmartTurnClassifierError.modelUnavailable
        }
        do {
            let environment = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setGraphOptimizationLevel(.all)
            self.environment = environment
            session = try ORTSession(
                env: environment,
                modelPath: resolvedURL.path,
                sessionOptions: options
            )
        } catch {
            throw SmartTurnClassifierError.modelUnavailable
        }
    }

    public func predict(samples: [Float], sampleRate: Double) throws -> SmartTurnPrediction {
        let started = ContinuousClock.now
        let features: [Float]
        do {
            features = try SmartTurnFeatureExtractor.features(
                from: samples,
                sampleRate: sampleRate
            )
        } catch {
            throw SmartTurnClassifierError.preprocessingFailed
        }
        let data = features.withUnsafeBytes { bytes in
            NSMutableData(bytes: bytes.baseAddress, length: bytes.count)
        }
        let input: ORTValue
        do {
            input = try ORTValue(
                tensorData: data,
                elementType: .float,
                shape: [
                    1,
                    NSNumber(value: SmartTurnFeatureExtractor.melCount),
                    NSNumber(value: SmartTurnFeatureExtractor.frameCount),
                ]
            )
        } catch {
            throw SmartTurnClassifierError.inferenceFailed
        }
        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(
                withInputs: ["input_features": input],
                outputNames: ["logits"],
                runOptions: nil
            )
        } catch {
            throw SmartTurnClassifierError.inferenceFailed
        }
        guard let output = outputs["logits"] else {
            throw SmartTurnClassifierError.invalidOutput
        }
        let outputData: NSMutableData
        do {
            outputData = try output.tensorData()
        } catch {
            throw SmartTurnClassifierError.invalidOutput
        }
        guard outputData.length == MemoryLayout<Float>.size else {
            throw SmartTurnClassifierError.invalidOutput
        }
        var probability: Float = 0
        outputData.getBytes(&probability, length: MemoryLayout<Float>.size)
        let duration = ContinuousClock.now - started
        let durationMilliseconds =
            Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        do {
            return try SmartTurnPrediction(
                probability: Double(probability),
                durationMilliseconds: durationMilliseconds
            )
        } catch {
            throw SmartTurnClassifierError.invalidOutput
        }
    }

    private static func packagedModelURL() -> URL? {
        Bundle.main.url(
            forResource: "smart-turn-v3.2-cpu",
            withExtension: "onnx"
        )
            ?? Bundle.module.url(
                forResource: "smart-turn-v3.2-cpu",
                withExtension: "onnx",
                subdirectory: "Resources"
            )
    }
}
