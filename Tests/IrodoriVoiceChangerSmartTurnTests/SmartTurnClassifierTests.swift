import Foundation
import Testing

@testable import IrodoriVoiceChangerSmartTurn

@Suite("SmartTurnClassifierTests")
struct SmartTurnClassifierTests {
    @Test
    func bundledModelMatchesPipecatZeroOracle() async throws {
        let classifier = try SmartTurnClassifier()

        let prediction = try await classifier.predict(samples: [], sampleRate: 16_000)

        #expect(prediction.isComplete)
        #expect(abs(prediction.probability - 0.987_036_7) < 0.01)
        #expect(prediction.durationMilliseconds > 0)
    }

    @Test
    func bundledModelMatchesPipecatSineOracle() async throws {
        let samples = (0..<16_000).map { index in
            Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / 16_000))
        }
        let classifier = try SmartTurnClassifier()

        let prediction = try await classifier.predict(samples: samples, sampleRate: 16_000)

        #expect(!prediction.isComplete)
        #expect(abs(prediction.probability - 0.106_508_88) < 0.05)
    }

    @Test
    func fortyEightKilohertzInputMatchesPipecatResamplingOracle() async throws {
        let samples = (0..<48_000).map { index in
            Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        let classifier = try SmartTurnClassifier()

        let prediction = try await classifier.predict(samples: samples, sampleRate: 48_000)

        #expect(!prediction.isComplete)
        #expect(abs(prediction.probability - 0.064_264_3) < 0.05)
    }

    @Test
    func missingModelFailsClosed() {
        let url = URL(filePath: "/private/tmp/irodori-missing-smart-turn.onnx")

        #expect(throws: SmartTurnClassifierError.modelUnavailable) {
            try SmartTurnClassifier(modelURL: url)
        }
    }
}
