import Foundation
import IOKit

/// CT-124: hardware identity anchor. The IOPlatformUUID survives reboots and
/// macOS upgrades but changes when the OS volume moves to different hardware —
/// exactly the Migration-Assistant signal device identity needs. A database
/// cloned to another Mac therefore reports a different anchor and must never
/// reuse the stored device ID.
public enum PlatformIdentity {
    /// Returns nil when the platform UUID is unavailable (e.g. sandboxes
    /// without IOKit access); callers treat nil as "unknown", never as
    /// "different machine".
    public static func currentHardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        ).takeRetainedValue() as? String, !property.isEmpty else {
            return nil
        }
        return property
    }
}
