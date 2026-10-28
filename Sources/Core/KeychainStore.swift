import Foundation

/// Read/write access to the Groq API key, behind a protocol.
///
/// `Keychain` is a caseless enum of static functions, which is the right shape for a
/// process-wide secret store and the wrong shape for a unit test: there is no seam, so
/// anything that touched it would write to the real login keychain and destroy the
/// owner's live key. Every component that needs the key takes one of these instead.
@MainActor
protocol GroqKeyStoring: AnyObject {
    func groqKey() -> String?
    /// `nil` or an all-whitespace string deletes the item. It never stores `""` —
    /// an empty secret reads as "configured" everywhere downstream and is a lie.
    func setGroqKey(_ key: String?)
}

/// The live implementation. A thin forwarder — all the real work (trimming,
/// empty-means-delete, accessibility class) already lives in `Keychain`.
@MainActor
final class KeychainGroqKeyStore: GroqKeyStoring {
    init() {}

    func groqKey() -> String? { Keychain.apiKey() }

    func setGroqKey(_ key: String?) { Keychain.setAPIKey(key) }
}

@MainActor
protocol OpenRouterKeyStoring: AnyObject {
    func openRouterKey() -> String?
    func setOpenRouterKey(_ key: String?)
}

@MainActor
final class KeychainOpenRouterKeyStore: OpenRouterKeyStoring {
    init() {}

    func openRouterKey() -> String? { Keychain.openRouterAPIKey() }

    func setOpenRouterKey(_ key: String?) { Keychain.setOpenRouterAPIKey(key) }
}
