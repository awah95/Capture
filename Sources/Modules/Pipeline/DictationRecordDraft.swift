import Foundation

/// Builds and amends the `DictationRecord` for one dictation.
///
/// Split out of the pipeline because it is arithmetic and bookkeeping — word counts,
/// stage timings, Groq's billing arithmetic — with no concurrency in it, and because
/// the pipeline's job is hard enough without also owning the shape of a stats row.
///
/// A record is **opened before the microphone starts** and amended when the dictation
/// resolves. That order is deliberate: a crash mid-dictation then leaves a row on disk
/// pointing at real audio, which is what makes the recording recoverable instead of an
/// orphaned file nobody knows the provenance of.
enum DictationRecordDraft {

    /// Groq's `whisper-large-v3-turbo`, per hour of audio.
    private static let turboUSDPerHour = 0.04
    /// Groq's accuracy-oriented `whisper-large-v3`, per hour of audio.
    private static let largeUSDPerHour = 0.111

    /// Groq bills a minimum of 10 seconds per request, so a 2-second tail segment
    /// costs the same as a 10-second one. Estimating without this would understate a
    /// heavily segmented dictation several times over.
    private static let minimumBilledSecondsPerRequest: TimeInterval = 10

    /// The row written at the start of a capture: everything already known, and an
    /// outcome that says plainly this dictation has not finished yet.
    static func opened(id: UUID,
                       startedAt: Date,
                       modeID: String,
                       targetBundleID: String?,
                       targetAppName: String?,
                       audioFileName: String,
                       voiceProcessingActive: Bool,
                       interruptedReason: String) -> DictationRecord {
        DictationRecord(
            id: id,
            startedAt: startedAt,
            speakingDuration: 0,
            rawText: "",
            finalText: "",
            modeID: modeID,
            targetBundleID: targetBundleID,
            targetAppName: targetAppName,
            wordCount: 0,
            rawWordCount: 0,
            segmentCount: 0,
            timings: Timings(),
            insertionOutcome: "",
            retryCount: 0,
            editDistanceRawToFinal: 0,
            audioFileName: audioFileName,
            audioBytes: 0,
            estimatedCostUSD: 0,
            vocabularyTermsSent: 0,
            voiceProcessingActive: voiceProcessingActive,
            outcome: .failed(reason: interruptedReason))
    }

    /// What the recording turned out to be, independent of whether it transcribed.
    static func applyRecording(to record: inout DictationRecord,
                               duration: TimeInterval,
                               segmentCount: Int,
                               dispatchedDurations: [TimeInterval],
                               audioURL: URL?,
                               voiceProcessingActive: Bool,
                               transcriptionProvider: TranscriptionProvider = .groq,
                               transcriptionModel: String = "whisper-large-v3-turbo",
                               liveTranscriptionEnabled: Bool = false,
                               retranscribeFinalWithBatch: Bool = false,
                               transcriptionResults: [SegmentResult]? = nil,
                               vocabularyTermsSent: Int = 0,
                               armingSeconds: TimeInterval = 0,
                               finalizeSeconds: TimeInterval = 0) {
        // The two stages that were previously invisible. Between them they accounted for
        // a ~750 ms residual in every record — time the user waits for, attributed to
        // nothing, and therefore impossible to argue about. Arming happens before speech
        // (it is felt as a delay before the HUD, and audio in that window is lost);
        // finalizing happens after the stop edge and is squarely on the perceived path.
        record.timings.armingMs = milliseconds(armingSeconds)
        record.timings.finalizeMs = milliseconds(finalizeSeconds)
        // A fact about the *request*, not about the transcript, so it is written for
        // a dictation that failed to transcribe too: the terms were still sent, and
        // the Vocabulary screen's "38 of 112 fit" claim has to be checkable against
        // what actually went out.
        record.vocabularyTermsSent = vocabularyTermsSent
        record.speakingDuration = duration
        record.segmentCount = segmentCount
        record.audioBytes = byteCount(of: audioURL)
        let transcriptionEntries = transcriptionUsageEntries(
            forDispatched: dispatchedDurations,
            model: transcriptionModel,
            provider: transcriptionProvider,
            recordedDuration: duration,
            liveTranscriptionEnabled: liveTranscriptionEnabled,
            retranscribeFinalWithBatch: retranscribeFinalWithBatch,
            results: transcriptionResults)
        let transcriptionCost = transcriptionEntries
            .compactMap(\.costUSD)
            .reduce(Decimal.zero, +)
        record.estimatedCostUSD = NSDecimalNumber(decimal: transcriptionCost).doubleValue
        record.usageEntries = transcriptionEntries
        record.timings.captureMs = milliseconds(duration)
        // What the hardware actually negotiated, not what was asked for — a silent
        // fallback to plain capture is exactly the sort of thing stats must not hide.
        record.voiceProcessingActive = voiceProcessingActive
    }

    /// What the transcript turned out to be, once it reached the cursor.
    static func applyTranscript(to record: inout DictationRecord,
                                rawText: String,
                                finalText: String,
                                insertionOutcome: InsertionOutcome,
                                whisperSeconds: TimeInterval,
                                llmSeconds: TimeInterval = 0,
                                insertSeconds: TimeInterval,
                                totalSeconds: TimeInterval) {
        record.rawText = rawText
        record.finalText = finalText
        record.rawWordCount = TextMetrics.wordCount(rawText)
        record.wordCount = TextMetrics.wordCount(finalText)
        record.editDistanceRawToFinal = TextMetrics.normalizedEditDistance(rawText, finalText)
        record.insertionOutcome = name(of: insertionOutcome)
        record.timings.whisperMs = milliseconds(whisperSeconds)
        // Kept apart from `whisperMs` deliberately: "the mode is slow" and "Groq is
        // slow" are different complaints with different fixes, and a stats screen
        // that folded them together could not tell the user which one they had.
        record.timings.llmMs = milliseconds(llmSeconds)
        record.timings.insertMs = milliseconds(insertSeconds)
        record.timings.totalMs = milliseconds(totalSeconds)
        // The transcript is stored either way — spec §17 promises the words are in
        // History even when the caret was somewhere they must not go. What changes is
        // the verdict: a refusal put nothing in front of the user and must not be
        // counted as a dictation that landed, by the capsule or by the stats.
        if insertionOutcome == .refusedSecureField {
            record.outcome = .failed(reason: Self.secureFieldRefusalReason)
        } else {
            record.outcome = .inserted
        }
    }

    /// Why a record can be `.failed` while holding a perfectly good transcript.
    static let secureFieldRefusalReason =
        "Secure field — nothing was inserted or copied. The text is in History."

    /// Words per minute over the time actually spent speaking, not over the wall clock
    /// — waiting for Groq is not dictating, and counting it would flatter the number.
    static func wordsPerMinute(words: Int, speakingDuration: TimeInterval) -> Int {
        guard speakingDuration > 0 else { return 0 }
        return Int((Double(words) / speakingDuration * 60).rounded())
    }

    // MARK: - Helpers

    static func estimatedCostUSD(
        forDispatched durations: [TimeInterval],
        model: String = "whisper-large-v3-turbo"
    ) -> Double {
        guard let rate = hourlyRate(for: model) else { return 0 }
        let billed = durations.reduce(0) { $0 + max(minimumBilledSecondsPerRequest, $1) }
        return billed / 3_600 * rate
    }

    static func transcriptionUsageEntries(
        forDispatched durations: [TimeInterval],
        model: String,
        provider: TranscriptionProvider = .groq,
        recordedDuration: TimeInterval = 0,
        liveTranscriptionEnabled: Bool = false,
        retranscribeFinalWithBatch: Bool = false,
        isRetry: Bool = false,
        results: [SegmentResult]? = nil
    ) -> [DictationUsageEntry] {
        let orderedResults = results?.sorted { $0.index < $1.index }
        if provider == .groq {
            return durations.enumerated().flatMap { (offset, duration) -> [DictationUsageEntry] in
                let result = orderedResults.flatMap {
                    $0.indices.contains(offset) ? $0[offset] : nil
                }
                let attemptCount = result?.attemptCount ?? 1
                guard attemptCount > 0 else { return [] }
                return (0..<attemptCount).map { attempt in
                    let isFinalAttempt = attempt == attemptCount - 1
                    let succeeded = isFinalAttempt && (result == nil || result?.text != nil)
                    let observedOutcome: DictationUsageOutcome? = result == nil
                        ? nil : (succeeded ? .succeeded : .failed)
                    let cost = succeeded ? hourlyRate(for: model).map { rate in
                        Decimal(max(minimumBilledSecondsPerRequest, duration) / 3_600 * rate)
                    } : nil
                    return DictationUsageEntry(
                        stage: .transcription,
                        providerID: provider.rawValue,
                        requestedModelID: model,
                        actualModelID: model,
                        promptTokens: nil,
                        completionTokens: nil,
                        reasoningTokens: nil,
                        cachedTokens: nil,
                        costUSD: cost,
                        costKind: cost == nil ? .unknown : .estimated,
                        generationID: nil,
                        audioSeconds: duration,
                        transcriptionPath: isRetry ? .retryBatch : .batchSegment,
                        isRetry: isRetry || attempt > 0,
                        outcome: observedOutcome)
                }
            }
        }

        guard recordedDuration > 0 else { return [] }
        if isRetry {
            return [localUsageEntry(
                provider: provider,
                modelID: provider.batchUsageModelID,
                audioSeconds: recordedDuration,
                path: .retryBatch,
                isRetry: true,
                outcome: orderedResults?.first.map { usageOutcome(for: $0) })]
        }

        if liveTranscriptionEnabled {
            var entries = [localUsageEntry(
                provider: provider,
                modelID: provider.streamingUsageModelID,
                audioSeconds: recordedDuration,
                path: .liveStream,
                isRetry: false,
                outcome: nil)]
            if provider == .localUnified && retranscribeFinalWithBatch {
                entries.append(localUsageEntry(
                    provider: provider,
                    modelID: provider.batchUsageModelID,
                    audioSeconds: recordedDuration,
                    path: .finalBatchRecheck,
                    isRetry: false,
                    outcome: nil))
            }
            return entries
        }

        return durations.enumerated().map { offset, duration in
            let result = orderedResults.flatMap {
                $0.indices.contains(offset) ? $0[offset] : nil
            }
            return localUsageEntry(
                provider: provider,
                modelID: provider.batchUsageModelID,
                audioSeconds: duration,
                path: .batchSegment,
                isRetry: false,
                outcome: result.map { usageOutcome(for: $0) })
        }
    }

    /// Completes the open transcription receipts after the pipeline knows whether
    /// text was produced. Only the selected/final pass owns the output words and
    /// post-release latency, so multi-pass local transcription never doubles them.
    static func finalizeTranscriptionUsage(
        in record: inout DictationRecord,
        rawText: String,
        whisperSeconds: TimeInterval,
        outcome: DictationUsageOutcome,
        isRetry: Bool,
        selectedPath: DictationTranscriptionPath? = nil,
        provider: TranscriptionProvider = .groq,
        recordedDuration: TimeInterval = 0,
        dispatchedDurations: [TimeInterval] = [],
        results: [SegmentResult]? = nil
    ) {
        guard var entries = record.usageEntries else { return }
        var matching = entries.indices.filter {
            entries[$0].stage == .transcription
                && (isRetry
                    ? entries[$0].transcriptionPath == .retryBatch
                    : entries[$0].transcriptionPath != .retryBatch)
        }

        // A streaming engine can fall back to a batch pass that was not part of the
        // configured happy path. Add that work only after the transcriber reports it.
        if let selectedPath,
           !matching.contains(where: { entries[$0].transcriptionPath == selectedPath }),
           provider.isLocal {
            let fallbackEntries = transcriptionUsageEntries(
                forDispatched: dispatchedDurations.isEmpty
                    ? [recordedDuration] : dispatchedDurations,
                model: provider.batchUsageModelID,
                provider: provider,
                recordedDuration: recordedDuration,
                isRetry: isRetry,
                results: results)
            entries.append(contentsOf: fallbackEntries)
            matching = entries.indices.filter {
                entries[$0].stage == .transcription
                    && (isRetry
                        ? entries[$0].transcriptionPath == .retryBatch
                        : entries[$0].transcriptionPath != .retryBatch)
            }
        }

        guard outcome == .succeeded else {
            for index in matching where entries[index].outcome == nil {
                entries[index].outcome = outcome
            }
            record.usageEntries = entries
            return
        }

        let candidates = selectedPath.map { path in
            matching.filter { entries[$0].transcriptionPath == path }
        } ?? matching
        let selected = candidates.last { entries[$0].outcome == .succeeded }
            ?? candidates.last { entries[$0].outcome == nil }
            ?? candidates.last
        if selectedPath == .batchSegment && provider.isLocal {
            // Reaching fallback proves only the configured live/final alternatives
            // failed. Other batch entries are sibling segments, not alternatives.
            for index in matching
                where entries[index].transcriptionPath == .liveStream
                    || entries[index].transcriptionPath == .finalBatchRecheck {
                if entries[index].outcome == nil { entries[index].outcome = .failed }
            }
        } else if selectedPath == .liveStream {
            for index in matching where entries[index].transcriptionPath == .finalBatchRecheck {
                if entries[index].outcome == nil { entries[index].outcome = .failed }
            }
        }
        if let selected {
            if entries[selected].outcome == nil { entries[selected].outcome = .succeeded }
            entries[selected].outputWordCount = TextMetrics.wordCount(rawText)
            entries[selected].latencyMs = milliseconds(whisperSeconds)
        }
        record.usageEntries = entries
    }

    private static func localUsageEntry(
        provider: TranscriptionProvider,
        modelID: String,
        audioSeconds: TimeInterval,
        path: DictationTranscriptionPath,
        isRetry: Bool,
        outcome: DictationUsageOutcome?
    ) -> DictationUsageEntry {
        DictationUsageEntry(
            stage: .transcription,
            providerID: provider.rawValue,
            requestedModelID: modelID,
            actualModelID: modelID,
            promptTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            cachedTokens: nil,
            costUSD: .zero,
            costKind: .noCharge,
            generationID: nil,
            audioSeconds: audioSeconds,
            transcriptionPath: path,
            isRetry: isRetry,
            outcome: outcome)
    }

    private static func usageOutcome(for result: SegmentResult) -> DictationUsageOutcome {
        result.text == nil ? .failed : .succeeded
    }

    private static func hourlyRate(for model: String) -> Double? {
        switch model {
        case "whisper-large-v3-turbo": return turboUSDPerHour
        case "whisper-large-v3": return largeUSDPerHour
        default: return nil
        }
    }

    private static func byteCount(of url: URL?) -> Int {
        guard let url,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize
        else { return 0 }
        return size
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1_000).rounded())
    }

    /// A stable string rather than the enum's own description, so the log stays
    /// decodable if `InsertionOutcome` is ever reshaped.
    private static func name(of outcome: InsertionOutcome) -> String {
        switch outcome {
        case .insertedDirect: return "insertedDirect"
        case .pastedViaKeyboard: return "pastedViaKeyboard"
        case .clipboardFallback: return "clipboardFallback"
        case .refusedSecureField: return "refusedSecureField"
        }
    }
}
