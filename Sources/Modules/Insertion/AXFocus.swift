import ApplicationServices
import AppKit
import Foundation

enum FocusedElementKind: Equatable, Sendable {
    case none
    case text
    case secure
    /// The element answered neither role nor subrole: *unavailable*, which is not the
    /// same answer as *not secure*. Recorded separately so the decision below is a
    /// decision and not an accident of a `nil` falling into `.text`.
    case unknownRole
}

enum InsertionPlan: Equatable, Sendable {
    case insertedDirect
    case pastedViaKeyboard
    case clipboardFallback(reason: String)
    /// Nothing inserted and nothing copied (spec §8, §17). Distinct from a clipboard
    /// fallback because a fallback *does* touch the pasteboard, and a password field is
    /// the one place where leaving the transcript lying around is worse than losing it
    /// from the caret — it is still in History either way.
    case refusedSecureField
}

/// What an attempted accessibility write actually achieved.
///
/// The distinction between `accepted` and `confirmed` is the whole point.
/// `AXUIElementSetAttributeValue` returning `.success` means the message was
/// accepted, **not** that the text is in the document — Chrome, Electron apps and
/// most web text fields accept it and do nothing. Treating "accepted" as "inserted"
/// made the first rung of this ladder unfalsifiable, so the paste and clipboard
/// rungs beneath it were unreachable and a whole dictation vanished with the app
/// reporting success.
enum AXWriteResult: Equatable, Sendable {
    /// No write was attempted (no trust, no focus, or a secure field).
    case notAttempted
    /// The API refused the write outright.
    case refused
    /// The API accepted it, but the element exposes no readable value, so whether
    /// anything landed is unknowable. Treated as failure: the paste path is more
    /// reliable than a claim nothing can check.
    case accepted
    /// Accepted, and the element's text demonstrably changed afterwards.
    case confirmed
}

/// Pure form of the insertion decision ladder.
func planInsertion(
    axTrusted: Bool,
    focusedElementKind: FocusedElementKind,
    axWrite: AXWriteResult,
    cgEventAvailable: Bool
) -> InsertionPlan {
    if axTrusted && focusedElementKind == .secure {
        return .refusedSecureField
    }

    // An element that would not say what it is still counts, because a confirmed write
    // is itself proof it was not a password field: a secure field never hands back its
    // plaintext value, so there would have been nothing to compare and nothing to
    // confirm. See `classifyFocusedElement` for why unknown is not treated as secure.
    if axTrusted, focusedElementKind == .text || focusedElementKind == .unknownRole,
       axWrite == .confirmed {
        return .insertedDirect
    }

    if cgEventAvailable {
        return .pastedViaKeyboard
    }

    return .clipboardFallback(reason: "keyboard paste unavailable")
}

/// Pure form of the secure-field decision, so *unavailable* can be tested apart from
/// *negative* — the difference between refusing to type into a password box and
/// refusing to type into every app that does not speak accessibility.
///
/// An unreadable role is treated as **not secure**, deliberately:
///
/// - Every secure input surface on this platform advertises itself. AppKit's
///   `NSSecureTextField` and the WebKit/Blink mapping of `input[type=password]` both
///   expose the `AXSecureTextField` subrole. An element that answers *nothing at all*
///   is an app that does not implement accessibility, not a password field hiding.
/// - The alternative costs more than it saves. Refusing on unknown means nothing
///   inserted *and* nothing on the clipboard in every Electron and web view — exactly
///   the "the dictation exists nowhere" failure the ladder was rebuilt to prevent.
///   Refusal is not a free safe default; from the user's seat it is data loss.
///
/// A missing *subrole* alone can never mean secure either: ordinary AppKit text fields
/// omit `AXSubrole` entirely, so reading that as secure would refuse every plain text
/// field in the system.
func classifyFocusedElement(role: String?, subrole: String?) -> FocusedElementKind {
    if subrole == (kAXSecureTextFieldSubrole as String) {
        return .secure
    }
    if role == nil, subrole == nil {
        return .unknownRole
    }
    return .text
}

struct AXFocusedElement {
    let element: AXUIElement
    let kind: FocusedElementKind
}

/// What the ladder needs from whatever holds the caret.
///
/// A seam, not decoration: `Inserter.insert` posts ⌘V and writes the pasteboard, so a
/// test driving the real thing would type into whichever app happened to be frontmost
/// and overwrite the owner's actual clipboard. Behind this protocol the refusal path can
/// be *executed* rather than asserted by inspection.
protocol InsertionTarget {
    var kind: FocusedElementKind { get }
    /// The character immediately before the caret, or nil for any doubt at all.
    func precedingCharacter() -> Character?
    func write(_ text: String) -> AXWriteResult
    func textValue() -> String?
}

struct AXInsertionTarget: InsertionTarget {
    let element: AXUIElement
    let kind: FocusedElementKind

    func precedingCharacter() -> Character? { AXFocus.precedingCharacter(of: element) }
    func write(_ text: String) -> AXWriteResult { AXFocus.write(text, on: element) }
    func textValue() -> String? { AXFocus.textValue(of: element) }
}

enum AXFocus {
    static func focusedElement() -> AXFocusedElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        let element = value as! AXUIElement
        return AXFocusedElement(element: element, kind: kind(of: element))
    }

    /// The focused element behind the ladder's seam.
    static func focusedTarget() -> InsertionTarget? {
        guard let focused = focusedElement() else { return nil }
        return AXInsertionTarget(element: focused.element, kind: focused.kind)
    }

    /// Bounds of the surface currently receiving text, in Accessibility/Quartz screen
    /// coordinates. The HUD uses this only to choose a display; insertion does not
    /// depend on it. A focused element is the most precise answer, with the frontmost
    /// app's focused window as the fallback for editors that omit element geometry.
    static func focusedSurfaceFrame() -> CGRect? {
        if let element = focusedElement()?.element,
           let frame = frame(of: element) {
            return frame
        }

        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }

        return frame(of: value as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        let positionAX = unsafeDowncast(positionValue as AnyObject, to: AXValue.self)
        let sizeAX = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)
        guard AXValueGetType(positionAX) == .cgPoint,
              AXValueGetType(sizeAX) == .cgSize else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size),
              size.width > 0,
              size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Writes at the caret and then checks whether the document actually changed.
    ///
    /// The read-back is the point. Without it the only available signal is the API's
    /// own return code, which reports that the message was delivered — a question
    /// nobody was asking.
    static func write(_ text: String, on element: AXUIElement) -> AXWriteResult {
        let before = textValue(of: element)

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .refused
        }

        // No readable value before or after means there is nothing to compare, so
        // the write is unverifiable rather than successful.
        guard let before, let after = textValue(of: element) else { return .accepted }
        return after == before ? .accepted : .confirmed
    }

    /// The element's text, when it exposes any. Not every focused element does —
    /// custom editors and many web views answer nothing at all.
    static func textValue(of element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute as CFString, on: element)
    }

    private static func kind(of element: AXUIElement) -> FocusedElementKind {
        classifyFocusedElement(
            role: stringAttribute(kAXRoleAttribute as CFString, on: element),
            subrole: stringAttribute(kAXSubroleAttribute as CFString, on: element)
        )
    }

    /// The character immediately before the caret, for the capitalization and spacing
    /// rules (spec §8) — and nil for every kind of doubt.
    ///
    /// `kAXStringForRangeParameterizedAttribute` is the same class of API as the write
    /// that once reported success while a whole dictation vanished: apps that do not
    /// really implement it answer with nothing, or with something that is not one
    /// character. A wrong answer here does not fail loudly, it silently rewrites what
    /// the user said — so anything unexpected is treated as no answer.
    static func precedingCharacter(of element: AXUIElement) -> Character? {
        guard let caret = caretLocation(of: element), caret > 0 else { return nil }
        return precedingCharacter(
            caretLocation: caret,
            characterBeforeCaret: string(
                in: CFRange(location: caret - 1, length: 1),
                of: element
            )
        )
    }

    /// Pure form of the above, so the lying-app path is testable without an app to lie.
    static func precedingCharacter(
        caretLocation: Int?,
        characterBeforeCaret: String?
    ) -> Character? {
        guard let caretLocation, caretLocation > 0 else { return nil }
        // Exactly one Character, which in Swift is one grapheme — a single emoji or a
        // CRLF pair both count as one. Two characters back means the range was ignored.
        guard let characterBeforeCaret, characterBeforeCaret.count == 1 else { return nil }
        return characterBeforeCaret.first
    }

    /// The caret offset, i.e. the start of the selected range. A selection about to be
    /// replaced still begins where the preceding character ends, so the location is the
    /// right question either way.
    static func caretLocation(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range.location
    }

    static func string(in range: CFRange, of element: AXUIElement) -> String? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    private static func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
