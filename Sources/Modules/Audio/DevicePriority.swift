import Foundation

/// Deterministically chooses an input without consulting CoreAudio or other process state.
///
/// Preferred UIDs are considered in policy order. The default fallback deliberately
/// excludes Continuity and virtual inputs so an iPhone or loopback driver cannot silently
/// replace the user's local microphone.
func selectDevice(
    available: [AudioInputDevice],
    policy: MicSelectionPolicy
) -> AudioInputDevice? {
    let eligible = available.filter {
        !policy.excludeContinuityInputs || !$0.isContinuityDevice
    }

    for preferredUID in policy.preferredDeviceUIDs {
        if let match = eligible.first(where: { $0.id == preferredUID }) {
            return match
        }
    }

    // An explicit list is an allowlist. Never silently record an unlisted headset.
    guard policy.preferredDeviceUIDs.isEmpty else { return nil }

    return eligible.first {
        !$0.isContinuityDevice
            && ($0.transport == .builtIn
                || $0.transport == .usb
                || $0.transport == .bluetooth)
    }
}
