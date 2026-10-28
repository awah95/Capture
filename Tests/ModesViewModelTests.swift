import XCTest
@testable import Captur

/// Spec §10.3 — the modes screen. `ModeTests` covers the model and the store; this
/// file covers only what the editor adds on top of them: the destructive actions,
/// duplication, hotkey conflict detection, validation, the per-app table, and the
/// "try it on your last dictation" preview.
///
/// Every test uses a temporary directory. Nothing here may touch the real
/// `~/Library/Application Support/Captur/modes.json`, and nothing here may reach
/// the network — the preview is an injected closure precisely so it cannot.
@MainActor
final class ModesViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("captur-modes-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func customMode(
        id: String,
        name: String,
        hotkey: KeyCombo? = nil,
        autoPaste: Bool? = nil
    ) -> Mode {
        Mode(
            id: id,
            name: name,
            symbol: "wand.and.stars",
            isBuiltIn: false,
            usesLLM: true,
            systemPrompt: "Rewrite it in pirate.",
            model: "openai/gpt-oss-20b",
            temperature: 0.4,
            includeClipboardContext: true,
            includeAppNameContext: false,
            autoPaste: autoPaste,
            hotkey: hotkey
        )
    }

    /// Carbon virtual keycodes, spelled out so a test reads as the keystroke it means.
    private enum Key {
        static let escape: UInt32 = 53
        static let `return`: UInt32 = 36
        static let space: UInt32 = 49
        static let r: UInt32 = 15
        static let k: UInt32 = 40
        static let one: UInt32 = 18
        static let two: UInt32 = 19
        static let nine: UInt32 = 25
    }

    private enum Mod {
        static let none: UInt32 = 0
        static let command: UInt32 = 0x0100
        static let shift: UInt32 = 0x0200
        static let option: UInt32 = 0x0800
        static let control: UInt32 = 0x1000
    }

    /// Records what the preview closure was handed, so a test can prove the preview
    /// ran against the draft the user is looking at rather than the saved mode.
    @MainActor
    private final class PreviewRecorder {
        struct Call: Equatable {
            var mode: Mode
            var source: ModePreviewSource
        }

        private(set) var calls: [Call] = []
        var result: Result<String, Error> = .success("Previewed text.")
        /// Runs inside the closure, before it returns. Used to re-enter the view model.
        var onCall: (() async -> Void)?

        func run(_ mode: Mode, _ source: ModePreviewSource) async -> Result<String, Error> {
            calls.append(Call(mode: mode, source: source))
            await onCall?()
            return result
        }
    }

    private func makeViewModel(
        directory: URL,
        bindings: HotkeyBindings = .default,
        lastDictation: String? = "um so the thing is we should ship it",
        lastTargetAppName: String? = "Mail",
        recorder: PreviewRecorder? = nil
    ) -> (ModesViewModel, ModeStore) {
        let store = ModeStore(directory: directory)
        let model = ModesViewModel(
            store: store,
            globalBindings: bindings,
            lastDictation: {
                lastDictation.map {
                    ModePreviewSource(rawText: $0, targetAppName: lastTargetAppName)
                }
            },
            preview: { mode, source in
                guard let recorder else { return .success("Previewed text.") }
                return await recorder.run(mode, source)
            }
        )
        return (model, store)
    }

    // MARK: - Deleting a built-in restores its default

    func testDeletingABuiltInRestoresItsDefaultRatherThanRemovingIt() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        model.select(modeID: "note")
        model.draft.name = "Jots"
        model.draft.systemPrompt = "Bullet it and nothing else."
        XCTAssertTrue(model.save().isEmpty)
        XCTAssertEqual(store.mode(id: "note")?.name, "Jots")

        XCTAssertEqual(model.delete(modeID: "note"), .resetToBuiltIn)

        XCTAssertEqual(store.mode(id: "note"), Mode.note)
        XCTAssertEqual(store.modes.count, Mode.builtIns.count)
        XCTAssertEqual(store.modes.map(\.id), Mode.builtIns.map(\.id))
    }

    /// The whole point of `NullableOverride`: an edit that set a hotkey and an
    /// auto-paste override has to come back byte-for-byte identical, not
    /// "identical except two fields that are now explicitly nil".
    func testResettingAnEditedBuiltInReturnsItByteForByte() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)

        model.select(modeID: "clean")
        model.draft.name = "Tidy"
        model.draft.autoPaste = true
        model.draft.hotkey = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option | Mod.shift)
        model.draft.temperature = 0.7
        XCTAssertTrue(model.save().isEmpty)
        XCTAssertNotEqual(store.mode(id: "clean"), Mode.clean)

        model.delete(modeID: "clean")

        XCTAssertEqual(store.mode(id: "clean"), Mode.clean)
        let reloaded = ModeStore(directory: directory)
        XCTAssertEqual(reloaded.mode(id: "clean"), Mode.clean)
    }

    /// Byte-for-byte equality is not enough on its own: an override that happens to
    /// re-state every shipped value would pass it while quietly freezing the mode
    /// against future app versions. Proving the override is *gone* needs a store
    /// standing in for a later release.
    func testResettingABuiltInLeavesNoOverrideBehind() throws {
        let directory = try makeDirectory()
        let (model, _) = makeViewModel(directory: directory)

        model.select(modeID: "note")
        model.draft.name = "Jots"
        XCTAssertTrue(model.save().isEmpty)
        model.delete(modeID: "note")

        var improved = Mode.note
        improved.systemPrompt = "An improved note prompt."
        let laterBuiltIns = Mode.builtIns.map { $0.id == "note" ? improved : $0 }

        let reloaded = ModeStore(directory: directory, builtIns: laterBuiltIns)
        XCTAssertEqual(reloaded.mode(id: "note")?.systemPrompt, "An improved note prompt.")
        XCTAssertEqual(reloaded.mode(id: "note")?.name, "Note")
    }

    func testDeletingACustomModeRemovesIt() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        store.update(customMode(id: "pirate", name: "Pirate"))

        XCTAssertEqual(model.delete(modeID: "pirate"), .deletedCustom)
        XCTAssertNil(store.mode(id: "pirate"))
    }

    func testDeletingAnUnknownModeIsReportedAndChangesNothing() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        XCTAssertEqual(model.delete(modeID: "ghost"), .unknownMode)
        XCTAssertEqual(store.modes, Mode.builtIns)
    }

    /// Deleting the mode being edited must not leave the editor pointed at something
    /// that no longer exists.
    func testDeletingTheSelectedCustomModeMovesTheSelectionSomewhereReal() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        store.update(customMode(id: "pirate", name: "Pirate"))
        model.select(modeID: "pirate")

        model.delete(modeID: "pirate")

        let selected = try XCTUnwrap(model.selectedModeID)
        XCTAssertNotEqual(selected, "pirate")
        XCTAssertNotNil(store.mode(id: selected))
        XCTAssertEqual(model.draft.id, selected)
    }

    /// Built-ins are the six shipped modes; the editor must not offer a route to a
    /// Captur with five.
    func testNoBuiltInCanBeRemovedFromTheList() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        for mode in Mode.builtIns {
            model.delete(modeID: mode.id)
        }
        XCTAssertEqual(store.modes, Mode.builtIns)
    }

    // MARK: - Duplication

    func testDuplicatingProducesAUniqueID() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        let copy = try XCTUnwrap(model.duplicate(modeID: "clean"))
        XCTAssertNotEqual(copy.id, "clean")
        XCTAssertEqual(Set(store.modes.map(\.id)).count, store.modes.count)
        XCTAssertNotNil(store.mode(id: copy.id))
    }

    /// The off-by-one trap. A store that already holds Clean, Clean copy and
    /// Clean copy 2 is exactly where a naive "copy \(n + 1)" scheme collides.
    func testDuplicatingProducesAnUnusedNameWhenCopiesAlreadyExist() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        store.update(customMode(id: "clean-copy", name: "Clean copy"))
        store.update(customMode(id: "clean-copy-2", name: "Clean copy 2"))

        let copy = try XCTUnwrap(model.duplicate(modeID: "clean"))

        XCTAssertEqual(copy.name, "Clean copy 3")
        let names = store.modes.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate produced a name that already existed")
    }

    func testDuplicatingTheSameModeRepeatedlyKeepsProducingFreshNamesAndIDs() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        let first = try XCTUnwrap(model.duplicate(modeID: "email"))
        let second = try XCTUnwrap(model.duplicate(modeID: "email"))
        let third = try XCTUnwrap(model.duplicate(modeID: "email"))

        XCTAssertEqual([first.name, second.name, third.name],
                       ["Email copy", "Email copy 2", "Email copy 3"])
        XCTAssertEqual(Set([first.id, second.id, third.id]).count, 3)
        XCTAssertEqual(Set(store.modes.map(\.id)).count, store.modes.count)
    }

    /// A duplicate whose generated id happens to be taken by an unrelated mode still
    /// has to be unique — ids and names are uniquified against different sets.
    func testADuplicateIDIsUniqueEvenWhenTheSluggedNameIsAlreadyTaken() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        store.update(customMode(id: "note-copy", name: "Zebra"))

        let copy = try XCTUnwrap(model.duplicate(modeID: "note"))

        XCTAssertEqual(copy.name, "Note copy")
        XCTAssertNotEqual(copy.id, "note-copy")
        XCTAssertEqual(store.mode(id: "note-copy")?.name, "Zebra")
    }

    func testADuplicateOfABuiltInIsNotItselfABuiltIn() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        let copy = try XCTUnwrap(model.duplicate(modeID: "verbatim"))

        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(store.mode(id: copy.id)?.isBuiltIn, false)
        // Structural fields still come from the source: a copy of Verbatim that
        // suddenly called out to a model would be a different product.
        XCTAssertFalse(copy.usesLLM)
    }

    /// Two modes cannot own one keystroke, so a duplicate starts with none. Copying
    /// the hotkey would create a conflict the user never asked for.
    func testADuplicateDoesNotInheritTheSourceHotkey() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        var edited = Mode.message
        edited.hotkey = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option)
        store.update(edited)

        let copy = try XCTUnwrap(model.duplicate(modeID: "message"))
        XCTAssertNil(copy.hotkey)
        XCTAssertEqual(store.mode(id: "message")?.hotkey, edited.hotkey)
    }

    func testADuplicateCarriesThePromptModelTemperatureAndToggles() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        let copy = try XCTUnwrap(model.duplicate(modeID: "email"))

        XCTAssertEqual(copy.systemPrompt, Mode.email.systemPrompt)
        XCTAssertEqual(copy.model, Mode.email.model)
        XCTAssertEqual(copy.temperature, Mode.email.temperature)
        XCTAssertEqual(copy.symbol, Mode.email.symbol)
        XCTAssertEqual(copy.includeClipboardContext, Mode.email.includeClipboardContext)
        XCTAssertEqual(copy.includeAppNameContext, Mode.email.includeAppNameContext)
    }

    /// Ids are ASCII slugs, so a name with no ASCII in it has almost nothing to slug.
    /// It must still produce a usable id, and a different one each time.
    func testDuplicatingAModeWithNoASCIIInItsNameStillGetsAUsableUniqueID() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        store.update(customMode(id: "jp", name: "日本語"))

        let first = try XCTUnwrap(model.duplicate(modeID: "jp"))
        let second = try XCTUnwrap(model.duplicate(modeID: "jp"))

        XCTAssertFalse(first.id.isEmpty)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(store.modes.map(\.id)).count, store.modes.count)
    }

    func testDuplicatingSelectsTheCopySoTheUserCanEditIt() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        let copy = try XCTUnwrap(model.duplicate(modeID: "clean"))
        XCTAssertEqual(model.selectedModeID, copy.id)
        XCTAssertEqual(model.draft.id, copy.id)
    }

    func testDuplicatingAnUnknownModeReturnsNil() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        XCTAssertNil(model.duplicate(modeID: "ghost"))
        XCTAssertEqual(store.modes, Mode.builtIns)
    }

    // MARK: - Adding a mode

    /// A new mode starts with the anti-injection clause already in its prompt. A
    /// blank prompt would answer the first question the user dictated into it.
    func testAddingAModeStartsFromASafeTemplate() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        let first = model.addMode()
        XCTAssertFalse(first.isBuiltIn)
        XCTAssertTrue(first.systemPrompt.contains(Mode.antiInjectionClause))
        XCTAssertTrue(ModesViewModel.knownChatModels.contains(first.model))
        XCTAssertNil(first.hotkey)
        XCTAssertEqual(model.selectedModeID, first.id)
        XCTAssertTrue(model.save().isEmpty, "the template must validate as it arrives")

        let second = model.addMode()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertEqual(Set(store.modes.map(\.id)).count, store.modes.count)
    }

    // MARK: - Hotkey conflicts: another mode

    func testAHotkeyAlreadyBoundToAnotherModeSurfacesAConflict() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        let combo = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option)
        var note = Mode.note
        note.hotkey = combo
        store.update(note)

        let conflict = model.hotkeyConflict(for: combo, excluding: "clean")
        XCTAssertEqual(conflict, .otherMode(id: "note", name: "Note"))
    }

    /// "Surfaces a conflict rather than silently stealing it" — the store must be
    /// untouched after a refused save.
    func testSavingAConflictingHotkeyIsRefusedAndStealsNothing() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        let combo = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option)
        var note = Mode.note
        note.hotkey = combo
        store.update(note)

        model.select(modeID: "clean")
        model.draft.name = "Tidy"
        model.draft.hotkey = combo
        let issues = model.save()

        XCTAssertEqual(issues, [.hotkeyConflict(.otherMode(id: "note", name: "Note"))])
        XCTAssertTrue(issues.contains { $0.isBlocking })
        XCTAssertNil(store.mode(id: "clean")?.hotkey)
        XCTAssertEqual(store.mode(id: "clean")?.name, "Clean", "a refused save must write nothing at all")
        XCTAssertEqual(store.mode(id: "note")?.hotkey, combo)
    }

    func testAModeKeepingItsOwnHotkeyIsNotAConflict() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        let combo = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option)

        model.select(modeID: "note")
        model.draft.hotkey = combo
        XCTAssertTrue(model.save().isEmpty)

        model.select(modeID: "note")
        model.draft.temperature = 0.5
        XCTAssertTrue(model.save().isEmpty, "re-saving a mode must not conflict with itself")
        XCTAssertEqual(store.mode(id: "note")?.hotkey, combo)
    }

    // MARK: - Hotkey conflicts: the global bindings

    func testAHotkeyMatchingAGlobalBindingSurfacesAConflict() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())

        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.space, carbonModifiers: Mod.option),
                                 excluding: "clean"),
            .globalBinding("Start or stop dictation"))
        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.space, carbonModifiers: Mod.option | Mod.shift),
                                 excluding: "clean"),
            .globalBinding("Capture a thought"))
        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.space, carbonModifiers: Mod.control | Mod.option),
                                 excluding: "clean"),
            .globalBinding("History palette"))
    }

    /// The global bindings are rebindable (Task 25 owns that screen), so what counts
    /// as a conflict has to follow them rather than the shipped defaults.
    func testConflictDetectionFollowsRebindableGlobalBindings() throws {
        var bindings = HotkeyBindings.default
        let moved = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option | Mod.shift)
        bindings.toggleDictation = moved
        let (model, _) = makeViewModel(directory: try makeDirectory(), bindings: bindings)

        XCTAssertEqual(model.hotkeyConflict(for: moved, excluding: "clean"),
                       .globalBinding("Start or stop dictation"))
        // ⌥Space is free now that the toggle moved.
        XCTAssertNil(model.hotkeyConflict(for: KeyCombo(keyCode: Key.space, carbonModifiers: Mod.option),
                                         excluding: "clean"))
    }

    func testAnUnsetGlobalBindingIsNotAConflict() throws {
        var bindings = HotkeyBindings.default
        bindings.toggleThought = nil
        let (model, _) = makeViewModel(directory: try makeDirectory(), bindings: bindings)

        XCTAssertNil(model.hotkeyConflict(
            for: KeyCombo(keyCode: Key.space, carbonModifiers: Mod.option | Mod.shift),
            excluding: "clean"))
    }

    // MARK: - Hotkey conflicts: the capture-scoped bindings

    func testEscapeReturnAndCommandRSurfaceTheirCaptureBindings() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())

        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.escape, carbonModifiers: Mod.none),
                                 excluding: "clean"),
            .captureBinding("Cancel a capture"))
        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.return, carbonModifiers: Mod.none),
                                 excluding: "clean"),
            .captureBinding("End a latched recording"))
        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.r, carbonModifiers: Mod.command),
                                 excluding: "clean"),
            .captureBinding("Retry after an error"))
    }

    /// Spec §4.1: 1–9 switch modes while recording. Binding a mode to a bare digit
    /// would fight the mechanism that switches to it.
    func testABareDigitSurfacesTheModeSwitchConflict() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())

        for keyCode in [Key.one, Key.two, Key.nine] {
            XCTAssertEqual(
                model.hotkeyConflict(for: KeyCombo(keyCode: keyCode, carbonModifiers: Mod.none),
                                     excluding: "clean"),
                .captureBinding("Switch modes while recording"),
                "keycode \(keyCode) should read as the mode switch, not as a generic bare key")
        }
    }

    /// While the push-to-talk modifier is physically held the digit arrives as ⌥1,
    /// so both forms are taken.
    func testADigitCarryingThePushToTalkModifierAlsoConflicts() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.one, carbonModifiers: Mod.option),
                                 excluding: "clean"),
            .captureBinding("Switch modes while recording"))
    }

    func testTheConflictingDigitFormFollowsThePushToTalkKey() throws {
        var bindings = HotkeyBindings.default
        bindings.pushToTalk = .modifier(.rightCommand)
        let (model, _) = makeViewModel(directory: try makeDirectory(), bindings: bindings)

        XCTAssertEqual(
            model.hotkeyConflict(for: KeyCombo(keyCode: Key.one, carbonModifiers: Mod.command),
                                 excluding: "clean"),
            .captureBinding("Switch modes while recording"))
        XCTAssertNil(model.hotkeyConflict(for: KeyCombo(keyCode: Key.one, carbonModifiers: Mod.option),
                                          excluding: "clean"))
    }

    /// The digit rule must not become a blanket ban: ⌃⌥1 never arrives during a
    /// capture, so it is a legitimate mode hotkey.
    func testADigitWithAnUnrelatedModifierIsAccepted() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        XCTAssertNil(model.hotkeyConflict(
            for: KeyCombo(keyCode: Key.one, carbonModifiers: Mod.control | Mod.option),
            excluding: "clean"))
    }

    /// A Carbon hotkey with no modifiers is global: it would swallow the key in every
    /// app on the Mac. Not a conflict with a specific binding, but never bindable.
    func testAModifierLessKeyIsRefused() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        XCTAssertEqual(model.hotkeyConflict(for: KeyCombo(keyCode: Key.k, carbonModifiers: Mod.none),
                                            excluding: "clean"),
                       .needsModifier)
    }

    func testAFreeComboIsAcceptedAndRoundTrips() throws {
        let directory = try makeDirectory()
        let (model, _) = makeViewModel(directory: directory)
        let combo = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option | Mod.shift)

        XCTAssertNil(model.hotkeyConflict(for: combo, excluding: "clean"))
        model.select(modeID: "clean")
        model.draft.hotkey = combo
        XCTAssertTrue(model.save().isEmpty)

        let reloaded = ModeStore(directory: directory)
        XCTAssertEqual(reloaded.mode(id: "clean")?.hotkey, combo)
    }

    func testClearingAModeHotkeyIsAlwaysAllowed() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)
        let combo = KeyCombo(keyCode: Key.k, carbonModifiers: Mod.control | Mod.option | Mod.shift)

        model.select(modeID: "clean")
        model.draft.hotkey = combo
        XCTAssertTrue(model.save().isEmpty)

        model.draft.hotkey = nil
        XCTAssertTrue(model.save().isEmpty)
        XCTAssertNil(store.mode(id: "clean")?.hotkey)
    }

    /// While the field is listening, ⌥Space has to land in it rather than starting a
    /// dictation, so the global hotkeys are suspended for exactly that long.
    func testTheHotkeyFieldAsksForGlobalHotkeysToBeSuspendedWhileItListens() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        var requests: [Bool] = []
        model.suspendGlobalHotkeys = { requests.append($0) }

        model.beginRecordingHotkey()
        XCTAssertTrue(model.isRecordingHotkey)
        model.endRecordingHotkey()

        // The field completion and view teardown may both arrive. A screen may
        // release only its own suspension, exactly once.
        model.endRecordingHotkey()

        XCTAssertFalse(model.isRecordingHotkey)
        XCTAssertEqual(requests, [true, false], "a suspend with no matching resume breaks every hotkey")
    }

    // MARK: - Per-app mapping

    func testThePerAppMapRejectsAModeIDThatNoLongerExists() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        XCTAssertEqual(model.setPerAppMode("ghost", forBundleID: "com.example.app"),
                       .rejectedUnknownMode("ghost"))
        XCTAssertNil(store.perAppMap["com.example.app"])
    }

    func testThePerAppMapAcceptsAKnownMode() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)

        XCTAssertEqual(model.setPerAppMode("note", forBundleID: "com.example.app"), .applied)
        XCTAssertEqual(store.perAppMap["com.example.app"], "note")

        let reloaded = ModeStore(directory: directory)
        XCTAssertEqual(reloaded.perAppMap["com.example.app"], "note")
    }

    func testThePerAppMapRejectsABlankBundleID() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        XCTAssertEqual(model.setPerAppMode("note", forBundleID: "   "), .rejectedBlankBundleID)
        XCTAssertEqual(store.perAppMap.count, ModeStore.defaultPerAppMap.count)
    }

    func testAPerAppMappingCanBeCleared() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        XCTAssertEqual(model.setPerAppMode(nil, forBundleID: "com.apple.mail"), .cleared)
        XCTAssertNil(store.perAppMap["com.apple.mail"])
    }

    /// Deleting a mode must not leave the map pointing at it.
    func testDeletingACustomModeDropsItsPerAppMappings() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)
        store.update(customMode(id: "pirate", name: "Pirate"))
        XCTAssertEqual(model.setPerAppMode("pirate", forBundleID: "com.example.ship"), .applied)
        XCTAssertEqual(model.setPerAppMode("pirate", forBundleID: "com.example.dock"), .applied)

        model.delete(modeID: "pirate")

        XCTAssertNil(store.perAppMap["com.example.ship"])
        XCTAssertNil(store.perAppMap["com.example.dock"])
        let ids = Set(store.modes.map(\.id))
        for (bundleID, modeID) in store.perAppMap {
            XCTAssertTrue(ids.contains(modeID), "\(bundleID) still maps to the deleted \(modeID)")
        }

        let reloaded = ModeStore(directory: directory)
        XCTAssertNil(reloaded.perAppMap["com.example.ship"])
    }

    /// The decision the dropped mapping encodes: that app resolves to the global
    /// default, which is what `ModeResolver` would have done with a dangling id
    /// anyway — minus a Settings row claiming an intention the user never had.
    func testAnAppWhoseMappingWasDroppedResolvesToTheDefaultMode() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        store.update(customMode(id: "pirate", name: "Pirate"))
        model.setPerAppMode("pirate", forBundleID: "com.example.ship")
        store.setDefaultModeID("message")

        model.delete(modeID: "pirate")

        let resolved = ModeResolver.resolve(
            explicitModeID: nil,
            frontmostBundleID: "com.example.ship",
            perAppMap: store.perAppMap,
            defaultModeID: store.defaultModeID,
            available: store.modes)
        XCTAssertEqual(resolved.id, "message")
    }

    /// Resetting a built-in is not a deletion, so its mappings stay.
    func testDeletingABuiltInKeepsItsPerAppMappings() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.delete(modeID: "email")
        XCTAssertEqual(store.perAppMap["com.apple.mail"], "email")
    }

    /// A mapping can also go stale outside the editor — a hand-edited file, or a
    /// mode deleted by an older build. Opening the screen cleans it up.
    func testStaleMappingsAreDroppedWhenTheEditorOpens() throws {
        let directory = try makeDirectory()
        let seed = ModeStore(directory: directory)
        seed.update(customMode(id: "pirate", name: "Pirate"))
        seed.setMode("pirate", forBundleID: "com.example.ship")
        // Bypass the view model, the way an older build or a hand edit would.
        seed.deleteCustom(id: "pirate")
        XCTAssertEqual(seed.perAppMap["com.example.ship"], "pirate", "precondition: the store keeps it")

        let (_, store) = makeViewModel(directory: directory)
        XCTAssertNil(store.perAppMap["com.example.ship"])
    }

    func testPerAppRowsAreSortedByDisplayNameAndNameTheirMode() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        for bundleID in store.perAppMap.keys {
            model.setPerAppMode(nil, forBundleID: bundleID)
        }
        model.setPerAppMode("email", forBundleID: "com.apple.mail")
        model.setPerAppMode("message", forBundleID: "com.tinyspeck.slackmacgap")
        model.setPerAppMode("code", forBundleID: "com.example.unnamed")
        model.appName = { ["com.apple.mail": "Mail",
                          "com.tinyspeck.slackmacgap": "Slack"][$0] }

        let rows = model.perAppRows
        // An app that is not installed falls back to its bundle id, never a blank.
        XCTAssertEqual(rows.map(\.displayName), ["com.example.unnamed", "Mail", "Slack"])
        XCTAssertEqual(rows.map(\.modeName), ["Code", "Email", "Message"])
        XCTAssertEqual(rows.map(\.modeID), ["code", "email", "message"])
        XCTAssertEqual(rows.first?.bundleID, "com.example.unnamed")
    }

    // MARK: - Validation

    func testTemperatureBoundariesAreAccepted() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        for value in [0.0, 2.0] {
            model.select(modeID: "clean")
            model.draft.temperature = value
            XCTAssertTrue(model.save().isEmpty, "\(value) is inside the accepted range")
            XCTAssertEqual(store.mode(id: "clean")?.temperature, value)
        }
    }

    func testATemperatureOutsideTheAcceptedRangeIsRejected() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())

        for value in [-0.01, 2.01, 7.0] {
            model.select(modeID: "clean")
            model.draft.temperature = value
            XCTAssertEqual(model.save(), [.temperatureOutOfRange(value)])
            XCTAssertEqual(store.mode(id: "clean")?.temperature, Mode.clean.temperature,
                           "\(value) must not reach the store")
        }
    }

    func testANonFiniteTemperatureIsRejected() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "clean")
        model.draft.temperature = .nan
        XCTAssertEqual(model.save(), [.temperatureNotFinite])
        XCTAssertEqual(store.mode(id: "clean")?.temperature, Mode.clean.temperature)
    }

    func testAnLLMModeWithNoModelIsRejected() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "clean")
        model.draft.model = "  "
        XCTAssertEqual(model.save(), [.modelMissing])
        XCTAssertEqual(store.mode(id: "clean")?.model, Mode.clean.model)
    }

    /// The namespace trap: `whisper-large-v3-turbo` is the *transcription* model. In a
    /// mode's `model` field it is a chat completion that will never succeed.
    func testATranscriptionModelIsRejectedAsAChatModel() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "clean")
        model.draft.model = GroqClient.defaultModel
        XCTAssertEqual(model.save(), [.modelIsTranscriptionModel(GroqClient.defaultModel)])
        XCTAssertEqual(store.mode(id: "clean")?.model, Mode.clean.model)
    }

    /// Spec §6.2 resolves an unknown model id at launch and warns; it does not fail a
    /// dictation over one. So the editor warns too, and still saves.
    func testAnUnrecognisedChatModelWarnsButSaves() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "clean")
        model.draft.model = "some-vendor/brand-new-model"

        let issues = model.save()
        XCTAssertEqual(issues, [.modelUnrecognised("some-vendor/brand-new-model")])
        XCTAssertFalse(issues.contains { $0.isBlocking })
        XCTAssertEqual(store.mode(id: "clean")?.model, "some-vendor/brand-new-model")
    }

    func testSwitchingProviderSelectsItsSafeDefaultModelAndThinkingLevel() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: Mode.message.id)

        model.setDraftProvider(.openRouter)

        XCTAssertEqual(model.draft.refinementProvider, .openRouter)
        XCTAssertEqual(model.draft.model, "google/gemini-3.8-flash")
        XCTAssertEqual(model.draft.reasoningEffort, .low)
        XCTAssertTrue(model.availableModelPresets.allSatisfy { $0.provider == .openRouter })
    }

    func testCustomModelIDIsAllowedWithAWarningAndKeepsThinkingSelection() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: Mode.clean.id)
        model.setDraftModel("vendor/custom-cleaner")
        model.draft.reasoningEffort = .medium

        let issues = model.save()

        XCTAssertEqual(issues, [.modelUnrecognised("vendor/custom-cleaner")])
        XCTAssertEqual(store.mode(id: Mode.clean.id)?.model, "vendor/custom-cleaner")
        XCTAssertEqual(store.mode(id: Mode.clean.id)?.reasoningEffort, .medium)
    }

    func testTheShippedChatModelsAreRecognised() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        for shipped in Mode.builtIns where shipped.usesLLM {
            model.select(modeID: shipped.id)
            XCTAssertTrue(model.save().isEmpty, "\(shipped.model) should be a recognised chat model")
        }
        XCTAssertTrue(ModesViewModel.knownChatModels.contains(Mode.clean.model))
        XCTAssertTrue(ModesViewModel.knownChatModels.contains(Mode.email.model))
    }

    func testAnEmptyNameIsRejected() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "clean")
        model.draft.name = "   "
        XCTAssertEqual(model.save(), [.nameEmpty])
        XCTAssertEqual(store.mode(id: "clean")?.name, "Clean")
    }

    /// A pass-through mode has no prompt and no model, and that is not an error.
    func testAPassThroughModeNeedsNeitherPromptNorModel() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        for id in ["verbatim", "code"] {
            model.select(modeID: id)
            XCTAssertTrue(model.save().isEmpty, "\(id) should validate with an empty model")
        }
    }

    func testAnInvalidDraftIsNeverWrittenEvenPartially() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)

        model.select(modeID: "note")
        model.draft.name = "Jots"
        model.draft.symbol = "star"
        model.draft.temperature = 9
        XCTAssertFalse(model.save().isEmpty)

        XCTAssertEqual(store.mode(id: "note"), Mode.note)
        let reloaded = ModeStore(directory: directory)
        XCTAssertEqual(reloaded.mode(id: "note"), Mode.note)
    }

    func testValidationIssuesAreReadableWithoutRunningTheSave() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "clean")
        model.draft.temperature = 5
        XCTAssertEqual(model.issues, [], "issues only reflect the last save attempt")
        model.save()
        XCTAssertEqual(model.issues, [.temperatureOutOfRange(5)])
        model.draft.temperature = 0.3
        model.save()
        XCTAssertEqual(model.issues, [], "a good save clears the previous complaint")
    }

    // MARK: - Auto-paste override, the three states

    func testTheAutoPasteOverrideRoundTripsThroughAllThreeStates() throws {
        let directory = try makeDirectory()
        let (model, _) = makeViewModel(directory: directory)

        for value: Bool? in [true, false, nil] {
            model.select(modeID: "message")
            model.draft.autoPaste = value
            XCTAssertTrue(model.save().isEmpty)

            let reloaded = ModeStore(directory: directory)
            XCTAssertEqual(reloaded.mode(id: "message")?.autoPaste, value,
                           "auto-paste \(String(describing: value)) did not survive a reload")
        }
    }

    /// "Follow the global setting" and "explicitly never auto-paste" are different
    /// answers; the editor must not turn the first into the second.
    func testClearingTheAutoPasteOverrideMeansFollowTheGlobalSettingNotOff() throws {
        let directory = try makeDirectory()
        let (model, _) = makeViewModel(directory: directory)

        model.select(modeID: "message")
        model.draft.autoPaste = false
        XCTAssertTrue(model.save().isEmpty)
        XCTAssertEqual(ModeStore(directory: directory).mode(id: "message")?.autoPaste, false)

        model.draft.autoPaste = nil
        XCTAssertTrue(model.save().isEmpty)

        let reloaded = ModeStore(directory: directory)
        XCTAssertNil(reloaded.mode(id: "message")?.autoPaste)
        XCTAssertEqual(reloaded.mode(id: "message"), Mode.message)
    }

    // MARK: - Selection and the draft

    func testSelectingAModeLoadsItIntoTheDraft() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "email")

        XCTAssertEqual(model.selectedModeID, "email")
        XCTAssertEqual(model.draft.id, "email")
        XCTAssertEqual(model.draft.name, "Email")
        XCTAssertEqual(model.draft.model, Mode.email.model)
        XCTAssertEqual(model.draft.systemPrompt, Mode.email.systemPrompt)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testTheEditorOpensOnTheDefaultMode() throws {
        let directory = try makeDirectory()
        let seed = ModeStore(directory: directory)
        seed.setDefaultModeID("note")

        let (model, _) = makeViewModel(directory: directory)
        XCTAssertEqual(model.selectedModeID, "note")
        XCTAssertTrue(model.selectedModeIsDefault)
    }

    func testTheSelectedSavedModeCanBecomeTheDefault() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "note")

        XCTAssertFalse(model.selectedModeIsDefault)
        XCTAssertTrue(model.saveAndUseSelectedModeAsDefault().isEmpty)

        XCTAssertEqual(store.defaultModeID, "note")
        XCTAssertTrue(model.selectedModeIsDefault)
    }

    func testUsingAnEditedModeAsDefaultSavesThePreviewedDraftFirst() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "note")
        model.draft.name = "Jots"
        model.draft.systemPrompt = "Make a compact list."

        XCTAssertTrue(model.saveAndUseSelectedModeAsDefault().isEmpty)

        XCTAssertEqual(store.defaultModeID, "note")
        XCTAssertEqual(store.mode(id: "note")?.name, "Jots")
        XCTAssertEqual(store.mode(id: "note")?.systemPrompt, "Make a compact list.")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testAnInvalidDraftCannotBecomeTheDefault() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "note")
        model.draft.name = "   "

        XCTAssertEqual(model.saveAndUseSelectedModeAsDefault(), [.nameEmpty])

        XCTAssertEqual(store.defaultModeID, "clean")
        XCTAssertEqual(store.mode(id: "note"), Mode.note)
    }

    func testEditingTheDraftDoesNotTouchTheStoreUntilSave() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "note")
        model.draft.name = "Jots"

        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(store.mode(id: "note")?.name, "Note")

        XCTAssertTrue(model.save().isEmpty)
        XCTAssertEqual(store.mode(id: "note")?.name, "Jots")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testRevertRestoresTheDraftFromTheStore() throws {
        let (model, store) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "note")
        model.draft.name = "Jots"
        model.draft.temperature = 1.5
        model.revert()

        XCTAssertEqual(model.draft.name, "Note")
        XCTAssertEqual(model.draft.temperature, Mode.note.temperature)
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertEqual(store.mode(id: "note"), Mode.note)
    }

    func testABuiltInIsReportedAsResettableOnlyOnceItHasBeenEdited() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        model.select(modeID: "note")
        XCTAssertFalse(model.canResetSelectedMode)

        model.draft.name = "Jots"
        XCTAssertTrue(model.save().isEmpty)
        XCTAssertTrue(model.canResetSelectedMode)

        model.delete(modeID: "note")
        XCTAssertFalse(model.canResetSelectedMode)
    }

    // MARK: - "Try it on your last dictation"

    func testTheProductionPreviewRunnerUsesTheRealModeContextWithoutInserting() async throws {
        let chat = FakeChatClient()
        chat.result = { _ in "  Previewed text.  " }
        var mode = Mode.clean
        mode.includeAppNameContext = true
        mode.includeClipboardContext = true
        let term = VocabularyTerm(
            id: UUID(), text: "Captur", soundsLike: nil, isPinned: false,
            useCount: 0, lastUsed: nil, appBundleIDs: [])
        var clipboardReads = 0
        let runner = ModePreviewRunner(
            chat: chat,
            apiKey: { "test-key" },
            vocabularyTerms: { [term] },
            clipboard: {
                clipboardReads += 1
                return "release context"
            })

        let result = await runner.run(
            mode: mode,
            source: ModePreviewSource(rawText: "um ship captur", targetAppName: "Mail"))

        guard case .success(let text) = result else {
            return XCTFail("expected a successful preview, got \(result)")
        }
        XCTAssertEqual(text, "Previewed text.")
        XCTAssertEqual(chat.callCount, 1)
        XCTAssertEqual(chat.calls.first?.userMessage, "um ship captur")
        XCTAssertEqual(chat.calls.first?.model, mode.model)
        XCTAssertEqual(chat.calls.first?.temperature, mode.temperature)
        XCTAssertEqual(chat.keysSeen, ["test-key"])
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertTrue(chat.calls.first?.systemMessage.contains("Mail") == true)
        XCTAssertTrue(chat.calls.first?.systemMessage.contains("Captur") == true)
        XCTAssertFalse(chat.calls.first?.systemMessage.contains("release context") == true)
    }

    func testPreviewHonorsTheContextMasterSwitch() async {
        let chat = FakeChatClient()
        var mode = Mode.clean
        mode.includeAppNameContext = true
        let runner = ModePreviewRunner(refinement: chat, apiKey: { _ in "test-key" },
            vocabularyTerms: { [] }, clipboard: { "must not be read" }, contextEnabled: { false })
        _ = await runner.run(mode: mode, source: ModePreviewSource(rawText: "hello", targetAppName: "Private app"))
        XCTAssertFalse(chat.calls.first?.systemMessage.contains("Private app") == true)
    }

    func testTheProductionPreviewRunnerDoesNotReadAnUnrequestedClipboard() async {
        let chat = FakeChatClient()
        var clipboardReads = 0
        let runner = ModePreviewRunner(
            chat: chat,
            apiKey: { "test-key" },
            vocabularyTerms: { [] },
            clipboard: {
                clipboardReads += 1
                return "private"
            })

        _ = await runner.run(
            mode: Mode.clean,
            source: ModePreviewSource(rawText: "hello", targetAppName: "Mail"))

        XCTAssertEqual(clipboardReads, 0)
        XCTAssertFalse(chat.calls.first?.systemMessage.contains("private") == true)
    }

    func testTheProductionPreviewRunnerRequiresAnAPIKeyBeforeCallingGroq() async {
        let chat = FakeChatClient()
        let runner = ModePreviewRunner(
            chat: chat,
            apiKey: { "  " },
            vocabularyTerms: { [] },
            clipboard: { nil })

        let result = await runner.run(
            mode: Mode.clean,
            source: ModePreviewSource(rawText: "hello", targetAppName: nil))

        guard case .failure(let error) = result else {
            return XCTFail("expected a missing-key failure")
        }
        XCTAssertEqual(error.localizedDescription,
                       "Add your Groq API key in Settings before running a preview.")
        XCTAssertEqual(chat.callCount, 0)
    }

    func testThePreviewRunsTheDraftAgainstTheLastDictationRawText() async throws {
        let recorder = PreviewRecorder()
        recorder.result = .success("So the thing is: we should ship it.")
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)

        model.select(modeID: "clean")
        await model.runPreview()

        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.source.rawText,
                       "um so the thing is we should ship it")
        XCTAssertEqual(recorder.calls.first?.source.targetAppName, "Mail")
        XCTAssertEqual(recorder.calls.first?.mode.id, "clean")
        XCTAssertEqual(model.previewState, .done("So the thing is: we should ship it."))
    }

    /// The button is next to the prompt editor, so it has to try what the user is
    /// looking at — not the last thing they saved.
    func testThePreviewUsesTheUnsavedDraftRatherThanTheStoredMode() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)

        model.select(modeID: "clean")
        model.draft.systemPrompt = "Translate it into Latin."
        model.draft.temperature = 1.1
        await model.runPreview()

        XCTAssertEqual(recorder.calls.first?.mode.systemPrompt, "Translate it into Latin.")
        XCTAssertEqual(recorder.calls.first?.mode.temperature, 1.1)
    }

    func testThePreviewIsUnavailableWithNoDictationsYet() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(),
                                       lastDictation: nil,
                                       recorder: recorder)
        model.select(modeID: "clean")
        await model.runPreview()

        XCTAssertEqual(model.previewState, .unavailable(ModesViewModel.Copy.noDictationToPreview))
        XCTAssertTrue(recorder.calls.isEmpty, "no dictation means nothing to send")
    }

    func testAnEmptyLastDictationIsTreatedAsNoDictation() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(),
                                       lastDictation: "   \n",
                                       recorder: recorder)
        model.select(modeID: "clean")
        await model.runPreview()

        XCTAssertEqual(model.previewState, .unavailable(ModesViewModel.Copy.noDictationToPreview))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    /// A pass-through mode has nothing to preview: what it inserts *is* the raw text.
    /// Sending it to a model anyway would bill the user to be shown their own words.
    func testPreviewingAPassThroughModeNeverCallsTheModel() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)

        model.select(modeID: "verbatim")
        await model.runPreview()

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(model.previewState, .skipped("um so the thing is we should ship it"))
    }

    func testAPreviewFailureIsSurfacedRatherThanSwallowed() async throws {
        let recorder = PreviewRecorder()
        recorder.result = .failure(NSError(domain: "Test", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Groq said no."]))
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)

        model.select(modeID: "clean")
        await model.runPreview()

        XCTAssertEqual(model.previewState, .failed("Groq said no."))
    }

    /// Re-entering while a call is in flight must not stack a second request on the
    /// same key. Driven from inside the closure so the ordering is deterministic.
    func testASecondPreviewIsIgnoredWhileOneIsInFlight() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)
        model.select(modeID: "clean")

        // Re-enters exactly once, so a missing guard fails the count assertion
        // instead of recursing forever.
        recorder.onCall = { [weak model] in
            guard let model, recorder.calls.count == 1 else { return }
            XCTAssertEqual(model.previewState, .running)
            await model.runPreview()
        }
        await model.runPreview()

        XCTAssertEqual(recorder.calls.count, 1)
    }

    func testSelectingADifferentModeClearsAStalePreview() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)

        model.select(modeID: "clean")
        await model.runPreview()
        XCTAssertNotEqual(model.previewState, .idle)

        model.select(modeID: "email")
        XCTAssertEqual(model.previewState, .idle,
                       "a result from another mode must not sit under a different prompt")
    }

    /// Nothing in this screen may reach Groq on its own. The default preview closure
    /// exists so an un-wired composition root cannot accidentally become a live call.
    func testTheDefaultPreviewClosureIsNotWiredToAnything() async throws {
        let store = ModeStore(directory: try makeDirectory())
        let model = ModesViewModel(store: store)

        model.select(modeID: "clean")
        await model.runPreview()

        XCTAssertEqual(model.previewState, .unavailable(ModesViewModel.Copy.previewNotConnected))
    }

    // MARK: - Honesty about what is not wired yet

    /// Task 16 wires modes into the pipeline. Until it lands, a prompt the user edits
    /// here changes nothing at dictation time, and the screen has to say so.
    func testTheScreenAdmitsWhenModesDoNotYetAffectDictation() throws {
        let store = ModeStore(directory: try makeDirectory())

        let unwired = ModesViewModel(store: store, modesAffectPipeline: false)
        XCTAssertEqual(unwired.pipelineNotice, ModesViewModel.Copy.modesNotWiredYet)

        let wired = ModesViewModel(store: store, modesAffectPipeline: true)
        XCTAssertNil(wired.pipelineNotice)
    }

    // MARK: - Hotkey display

    func testAHotkeyIsRenderedAsTheKeystrokeItIs() {
        XCTAssertEqual(
            ModesViewModel.displayString(for: KeyCombo(keyCode: Key.k,
                                                       carbonModifiers: Mod.control | Mod.option | Mod.shift)),
            "⌃⌥⇧K")
        XCTAssertEqual(
            ModesViewModel.displayString(for: KeyCombo(keyCode: Key.space, carbonModifiers: Mod.option)),
            "⌥Space")
        // Modifier order is fixed, not the order the bits were set in.
        XCTAssertEqual(
            ModesViewModel.displayString(for: KeyCombo(keyCode: Key.one,
                                                       carbonModifiers: Mod.command | Mod.control)),
            "⌃⌘1")
    }

    func testAnUnknownKeyCodeStillRendersSomething() {
        let rendered = ModesViewModel.displayString(for: KeyCombo(keyCode: 199, carbonModifiers: Mod.command))
        XCTAssertTrue(rendered.hasPrefix("⌘"))
        XCTAssertFalse(rendered.isEmpty)
    }

    func testCustomLocalModeSavesDuplicatesAndPreservesItsCloudSettings() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)
        let custom = model.addMode()
        model.draft.systemPrompt = "My custom instruction."
        model.draft.contextOptions.editSelectedText = true
        model.draft.includeClipboardContext = true
        let originalProvider = model.draft.refinementProvider
        let originalModel = model.draft.model
        model.setDraftCleanupChoice(.localS1Mini)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertTrue(model.save().isEmpty)
        let saved = try XCTUnwrap(store.mode(id: custom.id))
        XCTAssertTrue(saved.usesLocalCleanup)
        let copy = try XCTUnwrap(model.duplicate(modeID: custom.id))
        XCTAssertTrue(copy.usesLocalCleanup)
        XCTAssertEqual(ModeStore(directory: directory).mode(id: copy.id), copy)
        model.setDraftCleanupChoice(.currentMode)
        XCTAssertEqual(model.draft.systemPrompt, "My custom instruction.")
        XCTAssertTrue(model.draft.contextOptions.editSelectedText)
        XCTAssertTrue(model.draft.includeClipboardContext)
        XCTAssertEqual(model.draft.refinementProvider, originalProvider)
        XCTAssertEqual(model.draft.model, originalModel)
        XCTAssertTrue(model.save().isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.mode(id: copy.id)).usesProviderRefinement)
        XCTAssertTrue(try XCTUnwrap(store.mode(id: custom.id)).usesLocalCleanup)
    }

    func testLocalDraftDoesNotRequireUnusedCloudModelOrReasoning() throws {
        let (model, _) = makeViewModel(directory: try makeDirectory())
        model.draft.model = ""
        model.draft.reasoningEffort = .high
        model.setDraftCleanupChoice(.localS1Mini)
        XCTAssertTrue(model.save().isEmpty)
        model.setDraftCleanupChoice(.currentMode)
        XCTAssertTrue(model.save().contains(.modelMissing))
        model.setDraftCleanupChoice(.localS1Mini)
        model.draft.temperature = .nan
        XCTAssertTrue(model.save().contains(.temperatureNotFinite), "JSON cannot persist NaN, even in unused settings")
    }

    func testCleanupSwitchCannotPublishAnOldPreviewOrStartConcurrentWork() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)
        recorder.onCall = {
            model.setDraftCleanupChoice(.localS1Mini)
            await model.runPreview()
        }
        await model.runPreview()
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(model.previewState, .idle)
        recorder.onCall = nil
        await model.runPreview()
        XCTAssertEqual(recorder.calls.count, 2)
        XCTAssertTrue(recorder.calls.last?.mode.usesLocalCleanup == true)
        XCTAssertEqual(model.previewState, .done("Previewed text."))
    }

    func testCleanupAvailabilityIsReadWithoutDownloadingAModel() async throws {
        let model = ModesViewModel(store: ModeStore(directory: try makeDirectory()),
            localCleanupAvailability: { _ in LocalModelAvailability(isDownloaded: true, updateAvailable: true) })
        await model.refreshCleanupAvailability()
        XCTAssertEqual(model.cleanupAvailability?.isDownloaded, true)
        XCTAssertEqual(model.cleanupAvailability?.updateAvailable, true)
    }

    func testManagingLocalModelSavesDraftBeforeNavigationAndBlocksInvalidDraft() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)
        let custom = model.addMode()
        model.setDraftCleanupChoice(.localS1Mini)
        var navigations = 0
        model.openCleanupSettings = {
            XCTAssertTrue(store.mode(id: custom.id)?.usesLocalCleanup == true)
            XCTAssertTrue(ModeStore(directory: directory).mode(id: custom.id)?.usesLocalCleanup == true)
            navigations += 1
        }
        model.manageCleanupModel()
        XCTAssertEqual(navigations, 1)
        model.draft.name = ""
        model.manageCleanupModel()
        XCTAssertEqual(navigations, 1)
        XCTAssertTrue(model.issues.contains(.nameEmpty))
    }

    func testEditingPromptDuringPreviewDiscardsOldResultAndAllowsRetry() async throws {
        let recorder = PreviewRecorder()
        let (model, _) = makeViewModel(directory: try makeDirectory(), recorder: recorder)
        recorder.onCall = { model.draft.systemPrompt = "A different prompt." }
        await model.runPreview()
        XCTAssertEqual(model.previewState, .idle)
        recorder.onCall = nil
        await model.runPreview()
        XCTAssertEqual(model.previewState, .done("Previewed text."))
        XCTAssertEqual(recorder.calls.count, 2)
    }


    func testManagingLocalModelStaysOnDraftAfterSaveFailureAndCanRetry() throws {
        let directory = try makeDirectory()
        let (model, store) = makeViewModel(directory: directory)
        let url = directory.appendingPathComponent("modes.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        model.setDraftCleanupChoice(.localS1Mini)
        var navigations = 0
        model.openCleanupSettings = { navigations += 1 }
        model.manageCleanupModel()
        XCTAssertNotNil(store.lastSaveError)
        XCTAssertEqual(navigations, 0)
        try FileManager.default.removeItem(at: url)
        model.manageCleanupModel()
        XCTAssertNil(store.lastSaveError)
        XCTAssertEqual(navigations, 1)
        XCTAssertTrue(ModeStore(directory: directory).mode(id: "clean")?.usesLocalCleanup == true)
    }

}
