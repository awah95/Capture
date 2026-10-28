import XCTest
@testable import Captur

final class TranscriptionProviderTests: XCTestCase {
    func testBothOnDeviceProvidersAreClassifiedAsLocal() {
        XCTAssertTrue(TranscriptionProvider.localUnified.isLocal)
        XCTAssertTrue(TranscriptionProvider.localMoonshine.isLocal)
        XCTAssertTrue(TranscriptionProvider.localUltra.isLocal)
        XCTAssertTrue(TranscriptionProvider.localPhonon.isLocal)
        XCTAssertFalse(TranscriptionProvider.groq.isLocal)
    }

    func testLiveTranscriptionIsCapabilityGated() {
        XCTAssertFalse(TranscriptionProvider.groq.supportsLiveTranscription)
        XCTAssertFalse(TranscriptionProvider.localUltra.supportsLiveTranscription)
        XCTAssertFalse(TranscriptionProvider.localPhonon.supportsLiveTranscription)
        XCTAssertFalse(TranscriptionProvider.localPhonon.supportsAcousticVocabularyBoosting)
        XCTAssertTrue(TranscriptionProvider.localUnified.supportsLiveTranscription)
        XCTAssertTrue(TranscriptionProvider.localMoonshine.supportsLiveTranscription)

        guard case .additionalDownload(let size, _) =
            TranscriptionProvider.localUnified.liveTranscriptionCapability else {
            return XCTFail("Unified should declare its separate streaming artifact")
        }
        XCTAssertEqual(size, "≈565 MB")
    }

    func testUltraHasSeparateModelIdentityAndNoStreamingArtifact() throws {
        let ultra = try XCTUnwrap(LocalModelDescriptor.all.first { $0.provider == .localUltra })
        XCTAssertNil(ultra.streamingModelID)
        XCTAssertNotEqual(ultra.batchModelID, TranscriptionProvider.localUnified.batchUsageModelID)
        guard case .unsupported = TranscriptionProvider.localUltra.liveTranscriptionCapability else {
            return XCTFail("Ultra must not offer a live download")
        }
        var local = record()
        DictationRecordDraft.applyRecording(to: &local, duration: 12, segmentCount: 1,
            dispatchedDurations: [12], audioURL: nil, voiceProcessingActive: true,
            transcriptionProvider: .localUltra)
        XCTAssertEqual(local.estimatedCostUSD, 0)
        XCTAssertEqual(local.usageEntries?.first?.providerID, "localUltra")
        XCTAssertEqual(local.usageEntries?.first?.requestedModelID, ultra.batchModelID)
    }

    func testPhononUsageKeepsItsPinnedModelIdentityWithoutCloudCost() throws {
        let descriptor = try XCTUnwrap(LocalModelDescriptor.all.first { $0.provider == .localPhonon })
        var local = record()
        DictationRecordDraft.applyRecording(to: &local, duration: 12, segmentCount: 1,
            dispatchedDurations: [12], audioURL: nil, voiceProcessingActive: false,
            transcriptionProvider: .localPhonon)
        XCTAssertEqual(local.estimatedCostUSD, 0)
        XCTAssertEqual(local.usageEntries?.first?.providerID, "localPhonon")
        XCTAssertEqual(local.usageEntries?.first?.requestedModelID, descriptor.batchModelID)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionProvider.self,
            from: JSONEncoder().encode(TranscriptionProvider.localPhonon)), .localPhonon)
    }

    func testLocalTranscriptionDoesNotRecordAGroqSpeechCost() {
        var local = record()
        DictationRecordDraft.applyRecording(
            to: &local,
            duration: 12,
            segmentCount: 1,
            dispatchedDurations: [12],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .localUnified)

        var cloud = record()
        DictationRecordDraft.applyRecording(
            to: &cloud,
            duration: 12,
            segmentCount: 1,
            dispatchedDurations: [12],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .groq)

        XCTAssertEqual(local.estimatedCostUSD, 0)
        XCTAssertGreaterThan(cloud.estimatedCostUSD, 0)
    }

    func testGroqTranscriptionPricingUsesTheSelectedWhisperModel() {
        XCTAssertEqual(
            DictationRecordDraft.estimatedCostUSD(
                forDispatched: [3_600], model: "whisper-large-v3-turbo"),
            0.04,
            accuracy: 0.000_000_1)
        XCTAssertEqual(
            DictationRecordDraft.estimatedCostUSD(
                forDispatched: [3_600], model: "whisper-large-v3"),
            0.111,
            accuracy: 0.000_000_1)
    }

    func testEachDispatchedSegmentProducesItsOwnTranscriptionUsageEntry() {
        var cloud = record()
        DictationRecordDraft.applyRecording(
            to: &cloud,
            duration: 17,
            segmentCount: 2,
            dispatchedDurations: [5, 12],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .groq,
            transcriptionModel: "whisper-large-v3")

        let entries = cloud.usageEntries ?? []
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.stage == .transcription })
        XCTAssertTrue(entries.allSatisfy { $0.requestedModelID == "whisper-large-v3" })
        XCTAssertEqual(
            cloud.estimatedCostUSD,
            DictationRecordDraft.estimatedCostUSD(
                forDispatched: [5, 12], model: "whisper-large-v3"),
            accuracy: 0.000_000_1)
    }

    func testNoDispatchedRequestProducesNoInventedUsageEntry() {
        var cloud = record()
        DictationRecordDraft.applyRecording(
            to: &cloud,
            duration: 0,
            segmentCount: 0,
            dispatchedDurations: [],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .groq)

        XCTAssertEqual(cloud.usageEntries, [])
        XCTAssertEqual(cloud.estimatedCostUSD, 0)
    }

    func testLocalLivePlusBatchTracksBothPassesButCountsOutputOnce() {
        var local = record()
        DictationRecordDraft.applyRecording(
            to: &local,
            duration: 12,
            segmentCount: 1,
            dispatchedDurations: [12],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .localUnified,
            liveTranscriptionEnabled: true,
            retranscribeFinalWithBatch: true)

        DictationRecordDraft.finalizeTranscriptionUsage(
            in: &local,
            rawText: "three local words",
            whisperSeconds: 0.125,
            outcome: .succeeded,
            isRetry: false)

        let entries = local.usageEntries ?? []
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.providerID), [
            TranscriptionProvider.localUnified.rawValue,
            TranscriptionProvider.localUnified.rawValue,
        ])
        XCTAssertEqual(entries.map(\.transcriptionPath), [.liveStream, .finalBatchRecheck])
        XCTAssertEqual(entries.compactMap(\.audioSeconds).reduce(0, +), 24, accuracy: 0.0001)
        XCTAssertEqual(entries.compactMap(\.outputWordCount).reduce(0, +), 3)
        XCTAssertEqual(entries.compactMap(\.latencyMs), [125])
        XCTAssertTrue(entries.allSatisfy { $0.costUSD == .zero && $0.costKind == .noCharge })
        XCTAssertEqual(entries.compactMap(\.outcome), [.succeeded],
                       "only the pass whose output won is labelled successful")
    }

    func testLocalBatchKeepsEverySuccessfulSegmentSuccessful() {
        let results = [
            SegmentResult(index: 0, text: "first part", precedingSilence: 0),
            SegmentResult(index: 1, text: "second part", precedingSilence: 0.5),
        ]
        var local = record()
        DictationRecordDraft.applyRecording(
            to: &local,
            duration: 11,
            segmentCount: 2,
            dispatchedDurations: [5, 6],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .localUnified,
            transcriptionResults: results)

        DictationRecordDraft.finalizeTranscriptionUsage(
            in: &local,
            rawText: "first part second part",
            whisperSeconds: 0.2,
            outcome: .succeeded,
            isRetry: false,
            selectedPath: .batchSegment,
            provider: .localUnified,
            recordedDuration: 11,
            dispatchedDurations: [5, 6],
            results: results)

        let entries = local.usageEntries ?? []
        XCTAssertEqual(entries.map(\.outcome), [.succeeded, .succeeded])
        XCTAssertEqual(entries.compactMap(\.audioSeconds), [5, 6])
        XCTAssertEqual(entries.compactMap(\.outputWordCount).reduce(0, +), 4)
        XCTAssertEqual(entries.compactMap(\.latencyMs), [200])
    }

    func testGroqAutomaticRetriesProduceAttemptReceipts() {
        let results = [
            SegmentResult(index: 0, text: "eventually worked", precedingSilence: 0,
                          attemptCount: 3),
        ]
        var cloud = record()
        DictationRecordDraft.applyRecording(
            to: &cloud,
            duration: 12,
            segmentCount: 1,
            dispatchedDurations: [12],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .groq,
            transcriptionResults: results)

        DictationRecordDraft.finalizeTranscriptionUsage(
            in: &cloud,
            rawText: "eventually worked",
            whisperSeconds: 0.3,
            outcome: .succeeded,
            isRetry: false,
            selectedPath: .batchSegment,
            provider: .groq,
            recordedDuration: 12,
            dispatchedDurations: [12],
            results: results)

        let entries = cloud.usageEntries ?? []
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.outcome), [.failed, .failed, .succeeded])
        XCTAssertEqual(entries.map(\.isRetry), [false, true, true])
        XCTAssertEqual(entries.map(\.costKind), [.unknown, .unknown, .estimated])
        XCTAssertNil(entries[0].costUSD)
        XCTAssertNil(entries[1].costUSD)
        XCTAssertGreaterThan(NSDecimalNumber(decimal: entries[2].costUSD ?? 0).doubleValue, 0)
        XCTAssertEqual(entries.compactMap(\.outputWordCount), [2])
    }

    func testFailedLocalLiveFallbackStillRecordsItsBatchAttempts() {
        let results = [
            SegmentResult(index: 0, text: nil, precedingSilence: 0),
            SegmentResult(index: 1, text: nil, precedingSilence: 0.5),
        ]
        var local = record()
        DictationRecordDraft.applyRecording(
            to: &local,
            duration: 11,
            segmentCount: 2,
            dispatchedDurations: [5, 6],
            audioURL: nil,
            voiceProcessingActive: true,
            transcriptionProvider: .localUnified,
            liveTranscriptionEnabled: true,
            retranscribeFinalWithBatch: true,
            transcriptionResults: results)

        DictationRecordDraft.finalizeTranscriptionUsage(
            in: &local,
            rawText: "",
            whisperSeconds: 0.2,
            outcome: .failed,
            isRetry: false,
            selectedPath: .batchSegment,
            provider: .localUnified,
            recordedDuration: 11,
            dispatchedDurations: [5, 6],
            results: results)

        let entries = local.usageEntries ?? []
        XCTAssertEqual(entries.map(\.transcriptionPath), [
            .liveStream, .finalBatchRecheck, .batchSegment, .batchSegment,
        ])
        XCTAssertTrue(entries.allSatisfy { $0.outcome == .failed })
        XCTAssertEqual(entries.compactMap(\.audioSeconds).reduce(0, +), 33, accuracy: 0.0001)
    }

    private func record() -> DictationRecord {
        DictationRecordDraft.opened(
            id: UUID(),
            startedAt: Date(),
            modeID: "verbatim",
            targetBundleID: nil,
            targetAppName: nil,
            audioFileName: "test.flac",
            voiceProcessingActive: true,
            interruptedReason: "test")
    }
}
