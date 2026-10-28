import AppKit
import Foundation

/// Where the capsule was last dragged to, per display.
///
/// Keyed by the display's UUID rather than its index, because indices are reassigned
/// when a monitor is unplugged and the HUD would then reappear on the wrong screen.
/// The offset is stored relative to the screen's own origin so a rearranged desktop
/// keeps the capsule where the user put it.
struct CapsulePositionStore {

    static let defaultsKey = "hud.capsule.origins"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A stable identifier for a screen. `CGDisplayCreateUUIDFromDisplayID` survives
    /// re-plugging; the display number does not, so it is only the fallback.
    static func identifier(for screen: NSScreen) -> String {
        guard let displayID = displayID(for: screen) else { return "unknown" }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return "display-\(displayID)"
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// The saved offset from the screen's frame origin, if there is one.
    func offset(forDisplay identifier: String) -> CGPoint? {
        guard let stored = defaults.dictionary(forKey: Self.defaultsKey)?[identifier] as? [String: Any],
              let x = (stored["x"] as? NSNumber)?.doubleValue,
              let y = (stored["y"] as? NSNumber)?.doubleValue
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    func setOffset(_ offset: CGPoint, forDisplay identifier: String) {
        var all = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        all[identifier] = ["x": offset.x, "y": offset.y]
        defaults.set(all, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
