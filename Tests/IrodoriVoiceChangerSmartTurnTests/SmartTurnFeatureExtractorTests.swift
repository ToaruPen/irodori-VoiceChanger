import Foundation
import Testing

@testable import IrodoriVoiceChangerSmartTurn

@Suite("SmartTurnFeatureExtractorTests")
struct SmartTurnFeatureExtractorTests {
    @Test
    func zeroInputMatchesPipecatOracle() throws {
        let features = try SmartTurnFeatureExtractor.features(from: [], sampleRate: 16_000)

        #expect(features.count == 80 * 800)
        #expect(features.allSatisfy { abs($0 + 1.5) < 0.000_001 })
    }

    @Test
    func oneSecondSineMatchesPipecatOracle() throws {
        let samples = (0..<16_000).map { index in
            Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / 16_000))
        }

        let features = try SmartTurnFeatureExtractor.features(
            from: samples,
            sampleRate: 16_000
        )

        expectFeature(features, mel: 0, frame: 0, equals: -0.110_255_14)
        expectFeature(features, mel: 0, frame: 700, equals: 1.284_304_5)
        expectFeature(features, mel: 0, frame: 799, equals: 0.929_160_7)
        expectFeature(features, mel: 10, frame: 700, equals: 1.718_952_3)
        expectFeature(features, mel: 40, frame: 750, equals: -0.110_255_14)
        expectFeature(features, mel: 79, frame: 799, equals: -0.110_255_14)
        #expect(abs((features.min() ?? 0) - -0.110_255_14) < 0.002)
        #expect(abs((features.max() ?? 0) - 1.889_744_9) < 0.002)
        let mean = features.reduce(0, +) / Float(features.count)
        #expect(abs(mean - -0.096_049_64) < 0.002)
    }

    @Test
    func impulseMatchesPipecatOracleAcrossMelBands() throws {
        var samples = [Float](repeating: 0, count: 16_000)
        samples[8_000] = 0.75

        let features = try SmartTurnFeatureExtractor.features(
            from: samples,
            sampleRate: 16_000
        )

        expectFeature(features, mel: 0, frame: 0, equals: 0.319_641_98)
        expectFeature(features, mel: 0, frame: 750, equals: 1.873_077_3)
        expectFeature(features, mel: 10, frame: 750, equals: 1.873_246_9)
        expectFeature(features, mel: 40, frame: 750, equals: 1.880_845_2)
        expectFeature(features, mel: 79, frame: 750, equals: 1.873_520_6)
        #expect(abs((features.min() ?? 0) - -0.117_848_96) < 0.002)
        #expect(abs((features.max() ?? 0) - 1.882_151) < 0.002)
    }

    @Test
    func keepsOnlyTheLatestEightSeconds() throws {
        let samples = (0..<129_000).map { index in
            Float(0.1 * sin(2 * Double.pi * 220 * Double(index) / 16_000))
        }

        let long = try SmartTurnFeatureExtractor.features(from: samples, sampleRate: 16_000)
        let tail = try SmartTurnFeatureExtractor.features(
            from: Array(samples.suffix(128_000)),
            sampleRate: 16_000
        )

        #expect(long == tail)
    }

    @Test
    func rejectsInvalidSampleRate() {
        #expect(throws: SmartTurnFeatureError.invalidSampleRate) {
            try SmartTurnFeatureExtractor.features(from: [0], sampleRate: 0)
        }
    }

    private func expectFeature(
        _ features: [Float],
        mel: Int,
        frame: Int,
        equals expected: Float
    ) {
        #expect(abs(features[mel * 800 + frame] - expected) < 0.002)
    }
}
