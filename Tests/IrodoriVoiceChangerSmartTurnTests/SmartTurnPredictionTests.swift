import Testing

@testable import IrodoriVoiceChangerSmartTurn

@Suite("SmartTurnPredictionTests")
struct SmartTurnPredictionTests {
    @Test
    func acceptsBoundedFiniteProbability() throws {
        let prediction = try SmartTurnPrediction(probability: 0.75, durationMilliseconds: 12.5)

        #expect(prediction.probability == 0.75)
        #expect(prediction.isComplete)
        #expect(prediction.durationMilliseconds == 12.5)
    }

    @Test(arguments: [Double.nan, -.infinity, .infinity, -0.01, 1.01])
    func rejectsInvalidProbability(_ probability: Double) {
        #expect(throws: SmartTurnPredictionError.invalidProbability) {
            try SmartTurnPrediction(probability: probability, durationMilliseconds: 1)
        }
    }

    @Test(arguments: [Double.nan, -.infinity, .infinity, -0.01])
    func rejectsInvalidDuration(_ durationMilliseconds: Double) {
        #expect(throws: SmartTurnPredictionError.invalidDuration) {
            try SmartTurnPrediction(probability: 0.5, durationMilliseconds: durationMilliseconds)
        }
    }
}
