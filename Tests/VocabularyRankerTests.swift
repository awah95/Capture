import XCTest
@testable import Captur

final class VocabularyRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func term(
        _ text: String,
        pinned: Bool = false,
        uses: Int = 0,
        daysAgo: Double? = nil,
        apps: Set<String> = [],
        soundsLike: String? = nil
    ) -> VocabularyTerm {
        VocabularyTerm(
            id: UUID(),
            text: text,
            soundsLike: soundsLike,
            isPinned: pinned,
            useCount: uses,
            lastUsed: daysAgo.map { Date(timeIntervalSince1970: 1_000_000 - $0 * 86_400) },
            appBundleIDs: apps
        )
    }

    // MARK: - Ranking

    func test_pinnedTermsAlwaysComeFirst() {
        let selection = VocabularyRanker.select(
            from: [term("zebra", uses: 500, daysAgo: 0), term("aardvark", pinned: true)],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.terms.first?.text, "aardvark")
    }

    func test_recentUseOutranksOldFrequentUse() {
        let selection = VocabularyRanker.select(
            from: [term("stale", uses: 100, daysAgo: 60), term("fresh", uses: 3, daysAgo: 0)],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.terms.first?.text, "fresh")
    }

    func test_appAffinityBreaksATie() {
        let selection = VocabularyRanker.select(
            from: [
                term("generic", uses: 5, daysAgo: 1),
                term("slackish", uses: 5, daysAgo: 1, apps: ["com.tinyspeck.slackmacgap"])
            ],
            targetBundleID: "com.tinyspeck.slackmacgap",
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.terms.first?.text, "slackish")
    }

    func test_pinnedTermsAreOrderedAmongThemselvesByScore() {
        let selection = VocabularyRanker.select(
            from: [
                term("quiet", pinned: true),
                term("busy", pinned: true, uses: 40, daysAgo: 0),
                term("unpinned", uses: 900, daysAgo: 0)
            ],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.terms.map(\.text), ["busy", "quiet", "unpinned"])
    }

    func test_neverUsedTermRanksBelowARecentlyUsedTerm() {
        let selection = VocabularyRanker.select(
            from: [term("never"), term("recent", daysAgo: 3)],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.terms.map(\.text), ["recent", "never"])
    }

    func test_appAffinityIsIgnoredWhenNoTargetBundleIDIsGiven() {
        // With no target app the bonus must not apply, so the alphabetical
        // tie-break decides between two otherwise identical terms.
        let selection = VocabularyRanker.select(
            from: [
                term("zulu", uses: 5, daysAgo: 1, apps: ["com.tinyspeck.slackmacgap"]),
                term("alpha", uses: 5, daysAgo: 1)
            ],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.terms.map(\.text), ["alpha", "zulu"])
    }

    func test_orderingIsDeterministic() {
        let vocabulary = (0..<40).map {
            term("term\($0)", pinned: $0 % 7 == 0, uses: $0 % 5, daysAgo: Double($0 % 11))
        }
        let first = VocabularyRanker.select(
            from: vocabulary, targetBundleID: nil, now: now, reservedTokens: 0
        )
        let second = VocabularyRanker.select(
            from: vocabulary, targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.terms.map(\.text), second.terms.map(\.text))
    }

    func test_identicalTermsTieBreakDeterministicallyRegardlessOfInputOrder() {
        let alpha = term("same", uses: 3, daysAgo: 1)
        let beta = term("same", uses: 3, daysAgo: 1)
        let forwards = VocabularyRanker.select(
            from: [alpha, beta], targetBundleID: nil, now: now, reservedTokens: 0
        )
        let backwards = VocabularyRanker.select(
            from: [beta, alpha], targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertEqual(forwards.terms.map(\.id), backwards.terms.map(\.id))
    }

    // MARK: - Prompt shape

    func test_emptyVocabularyProducesAnEmptyPrompt() {
        let selection = VocabularyRanker.select(
            from: [], targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertEqual(selection.promptString, "")
        XCTAssertEqual(selection.estimatedTokens, 0)
        XCTAssertEqual(selection.totalTermCount, 0)
        XCTAssertTrue(selection.terms.isEmpty)
    }

    func test_promptIsACommaSeparatedListInSendOrder() {
        let selection = VocabularyRanker.select(
            from: [term("Beta", pinned: true), term("Alpha", pinned: true)],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.promptString, "Alpha, Beta")
    }

    func test_soundsLikeHintIsRenderedAsAParentheticalAfterTheTerm() {
        let selection = VocabularyRanker.select(
            from: [term("Kubernetes", pinned: true, soundsLike: "koo-ber-net-ees")],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.promptString, "Kubernetes (koo-ber-net-ees)")
    }

    func test_blankSoundsLikeHintIsOmitted() {
        let selection = VocabularyRanker.select(
            from: [term("Kubernetes", pinned: true, soundsLike: "   ")],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.promptString, "Kubernetes")
    }

    func test_blankTermsAreNeverSent() {
        let selection = VocabularyRanker.select(
            from: [term("  ", pinned: true), term("real")],
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertEqual(selection.promptString, "real")
        XCTAssertEqual(selection.terms.map(\.text), ["real"])
        // The pre-truncation count still reports everything the user has stored.
        XCTAssertEqual(selection.totalTermCount, 2)
    }

    // MARK: - Budgeting

    func test_neverExceedsTheTokenBudget() {
        let many = (0..<400).map { term("supercalifragilistic\($0)") }
        let selection = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertLessThanOrEqual(
            selection.estimatedTokens, VocabularyRanker.whisperPromptTokenBudget
        )
        XCTAssertEqual(selection.totalTermCount, 400)
        XCTAssertLessThan(selection.terms.count, 400)
        XCTAssertFalse(selection.terms.isEmpty)
    }

    func test_reportedTokenCountMatchesTheEmittedPrompt() {
        let many = (0..<400).map { term("supercalifragilistic\($0)") }
        let selection = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertEqual(
            selection.estimatedTokens,
            VocabularyRanker.estimatedTokens(in: selection.promptString)
        )
    }

    func test_soundsLikeHintsAreCountedAgainstTheBudget() {
        let many = (0..<400).map {
            term("supercalifragilistic\($0)", soundsLike: "soo-per-cal-ee-fraj-il-istic")
        }
        let selection = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertLessThanOrEqual(
            selection.estimatedTokens, VocabularyRanker.whisperPromptTokenBudget
        )
        let withoutHints = VocabularyRanker.select(
            from: (0..<400).map { term("supercalifragilistic\($0)") },
            targetBundleID: nil,
            now: now,
            reservedTokens: 0
        )
        XCTAssertLessThan(selection.terms.count, withoutHints.terms.count)
    }

    func test_reservedTokensShrinkTheAvailableBudget() {
        let many = (0..<400).map { term("term\($0)") }
        let full = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: 0
        )
        let held = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: 100
        )
        XCTAssertLessThan(held.terms.count, full.terms.count)
        XCTAssertLessThanOrEqual(
            held.estimatedTokens, VocabularyRanker.whisperPromptTokenBudget - 100
        )
    }

    func test_reservedTokensLargerThanTheBudgetSendNothing() {
        let many = (0..<400).map { term("term\($0)") }
        let selection = VocabularyRanker.select(
            from: many,
            targetBundleID: nil,
            now: now,
            reservedTokens: VocabularyRanker.whisperPromptTokenBudget + 50
        )
        XCTAssertTrue(selection.terms.isEmpty)
        XCTAssertEqual(selection.promptString, "")
        XCTAssertEqual(selection.estimatedTokens, 0)
        XCTAssertEqual(selection.totalTermCount, 400)
    }

    func test_negativeReservedTokensCannotInflateTheBudget() {
        let many = (0..<400).map { term("term\($0)") }
        let selection = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: -500
        )
        XCTAssertLessThanOrEqual(
            selection.estimatedTokens, VocabularyRanker.whisperPromptTokenBudget
        )
    }

    func test_aSingleTermLargerThanTheBudgetIsDroppedWithoutCrashing() {
        let giant = term(String(repeating: "z", count: 5_000), pinned: true)
        let selection = VocabularyRanker.select(
            from: [giant], targetBundleID: nil, now: now, reservedTokens: 0
        )
        XCTAssertTrue(selection.terms.isEmpty)
        XCTAssertEqual(selection.promptString, "")
        XCTAssertEqual(selection.estimatedTokens, 0)
        XCTAssertEqual(selection.totalTermCount, 1)
    }

    func test_truncationKeepsTheHighestRankedTermsAndDropsTheRest() {
        // Every term scores identically, so the deterministic tie-break (text
        // ascending) is the whole ranking and the survivors must be its prefix.
        let many = (0..<400).map { term("term\($0)") }
        let selection = VocabularyRanker.select(
            from: many, targetBundleID: nil, now: now, reservedTokens: 0
        )
        let expected = many.map(\.text).sorted().prefix(selection.terms.count)
        XCTAssertEqual(selection.terms.map(\.text), Array(expected))
    }

    // MARK: - Token estimation

    func test_estimatedTokensAppliesTheSafetyMargin() {
        // ceil(ceil(8 / 4) * 1.15) == ceil(2.3) == 3
        XCTAssertEqual(VocabularyRanker.estimatedTokens(in: "abcdefgh"), 3)
        // ceil(ceil(1 / 4) * 1.15) == ceil(1.15) == 2
        XCTAssertEqual(VocabularyRanker.estimatedTokens(in: "a"), 2)
    }

    func test_estimatedTokensOfAnEmptyStringIsZero() {
        XCTAssertEqual(VocabularyRanker.estimatedTokens(in: ""), 0)
    }

    func test_estimatedTokensOverEstimatesRatherThanUnderEstimates() {
        let text = String(repeating: "word ", count: 100) // 500 characters
        XCTAssertGreaterThan(VocabularyRanker.estimatedTokens(in: text), 500 / 4)
    }
}
