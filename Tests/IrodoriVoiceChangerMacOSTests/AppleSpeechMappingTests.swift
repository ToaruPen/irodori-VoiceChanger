import Foundation
import Testing

@testable import IrodoriVoiceChangerCore
@testable import IrodoriVoiceChangerMacOS

@Suite("AppleSpeechMappingTests")
struct AppleSpeechMappingTests {
    @Test
    func detectorAndTranscriptResultsShareOneUtterance() throws {
        let fixedID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000020"))
        var mapper = AppleSpeechResultMapper(idGenerator: {
            fixedID
        })

        let started = try #require(mapper.mapDetection(speechDetected: true).first)
        let partial = try #require(mapper.mapTranscription(text: "こん", isFinal: false).last)
        let ended = try #require(mapper.mapDetection(speechDetected: false).first)
        let final = try #require(mapper.mapTranscription(text: "こんにちは", isFinal: true).last)

        let id = try #require(started.utteranceID)
        #expect(started == .speechStarted(id))
        #expect(partial == .partial(id, text: "こん", revisionCount: 0))
        #expect(ended == .speechEnded(id))
        #expect(final == .final(id, text: "こんにちは", revisionCount: 1))
    }

    @Test
    func partialBeforeDetectorStartsAnUtteranceAndTracksOnlyChanges() throws {
        var mapper = AppleSpeechResultMapper(idGenerator: UUID.init)

        let firstEvents = mapper.mapTranscription(text: "あ", isFinal: false)
        let first = try #require(firstEvents.last)
        let same = try #require(mapper.mapTranscription(text: "あ", isFinal: false).last)
        let changed = try #require(mapper.mapTranscription(text: "あい", isFinal: false).last)
        let id = try #require(first.utteranceID)

        #expect(first == .partial(id, text: "あ", revisionCount: 0))
        #expect(same == .partial(id, text: "あ", revisionCount: 0))
        #expect(changed == .partial(id, text: "あい", revisionCount: 1))
        #expect(firstEvents.first == .speechStarted(id))
    }

    @Test
    func emptyTranscriptsAndDuplicateDetectorTransitionsAreIgnored() {
        var mapper = AppleSpeechResultMapper(idGenerator: UUID.init)

        #expect(mapper.mapTranscription(text: "   ", isFinal: false).isEmpty)
        #expect(mapper.mapDetection(speechDetected: false).isEmpty)
        #expect(!mapper.mapDetection(speechDetected: true).isEmpty)
        #expect(mapper.mapDetection(speechDetected: true).isEmpty)
    }

    @Test
    func finalResultSynthesizesEndBoundaryWhenDetectorDoesNotReportOne() throws {
        var mapper = AppleSpeechResultMapper(idGenerator: UUID.init)
        let events = mapper.mapTranscription(text: "完了", isFinal: true)
        let id = try #require(events.first?.utteranceID)

        #expect(
            events == [
                .speechStarted(id),
                .speechEnded(id),
                .final(id, text: "完了", revisionCount: 0),
            ])
    }

    @Test
    func staleDetectorResultAfterFinalCannotCreateAPhantomUtterance() {
        var mapper = AppleSpeechResultMapper(idGenerator: UUID.init)
        let finalRange = SpeechAudioRange(startSeconds: 1, endSeconds: 2)

        _ = mapper.mapTranscription(text: "完了", isFinal: true, range: finalRange)
        let stale = mapper.mapDetection(
            speechDetected: true,
            range: .init(startSeconds: 1.1, endSeconds: 1.9)
        )
        let next = mapper.mapDetection(
            speechDetected: true,
            range: .init(startSeconds: 2.5, endSeconds: 2.6)
        )

        #expect(stale.isEmpty)
        #expect(next.count == 1)
    }

    @Test
    func staleDetectorEndCannotCloseTheNextUtterance() {
        var mapper = AppleSpeechResultMapper(idGenerator: UUID.init)
        _ = mapper.mapTranscription(
            text: "前",
            isFinal: true,
            range: .init(startSeconds: 1, endSeconds: 2)
        )
        _ = mapper.mapDetection(
            speechDetected: true,
            range: .init(startSeconds: 3, endSeconds: 3.1)
        )

        let staleEnd = mapper.mapDetection(
            speechDetected: false,
            range: .init(startSeconds: 1.8, endSeconds: 2.2)
        )

        #expect(staleEnd.isEmpty)
    }

    @Test
    func staleTranscriptionCannotFinalizeTheNextDetectorUtterance() {
        var mapper = AppleSpeechResultMapper(idGenerator: UUID.init)
        _ = mapper.mapTranscription(
            text: "前", isFinal: true, range: .init(startSeconds: 1, endSeconds: 2))
        _ = mapper.mapDetection(
            speechDetected: true, range: .init(startSeconds: 3, endSeconds: 3.1))

        let stale = mapper.mapTranscription(
            text: "古い結果", isFinal: true, range: .init(startSeconds: 1, endSeconds: 2))
        let current = mapper.mapTranscription(
            text: "次", isFinal: false, range: .init(startSeconds: 3, endSeconds: 3.5))

        #expect(stale.isEmpty)
        #expect(
            current.contains { event in
                if case .partial(_, let text, _) = event { return text == "次" }
                return false
            })
    }

    @Test
    func eventStreamOverflowFailsInsteadOfSilentlyDropping() throws {
        let (stream, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        _ = stream

        try yieldSpeechEvent(.speechStarted(UUID()), to: continuation)
        #expect(throws: AppleSpeechSessionError.eventBufferOverflow) {
            try yieldSpeechEvent(.speechStarted(UUID()), to: continuation)
        }
        continuation.finish()
    }

}

private extension SpeechEvent {
    var utteranceID: UUID? {
        switch self {
        case .speechStarted(let id), .speechEnded(let id):
            return id
        case .partial(let id, _, _), .final(let id, _, _):
            return id
        case .timing(let id, _, _):
            return id
        }
    }
}
