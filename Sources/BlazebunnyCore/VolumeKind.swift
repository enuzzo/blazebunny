import Foundation
import IOKit

/// What kind of disk a folder is on, to decide how many files to read at once.
public enum VolumeKind: String, Sendable {
    /// Flash storage: the disk keeps up with any number of readers, so the limit is the processor
    /// (making a thumbnail is mostly decoding the original). Measured on 12 000 generated PNGs of 1 to
    /// 11 megapixels, 12 performance and 4 efficiency cores: 122 thumbnails a second with 6 files at
    /// once, 209 with 12, 251 with 16.
    case solidState
    /// A spinning disk: more than two readers make the head seek back and forth.
    case rotational
    /// Network shares, disk images, enclosures that do not say what they hold: treated like a spinning disk.
    case unknown

    public init(of folder: URL) {
        self = Self.detect(folder)
    }

    public var recommendedIOConcurrency: Int {
        switch self {
        // Two cores are left to the app and the system; never fewer than 6 files at once (the old
        // fixed number), never more than 12 (each file is held whole in memory while it is decoded).
        case .solidState: return min(12, max(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        case .rotational, .unknown: return 2
        }
    }

    private static func detect(_ folder: URL) -> VolumeKind {
        var fs = statfs()
        guard statfs(folder.path, &fs) == 0 else { return .unknown }
        let device = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        // Only real local disks ("/dev/disk3s5") are looked up; a network or virtual mount is unknown.
        guard device.hasPrefix("/dev/"), fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return .unknown }
        let bsdName = String(device.dropFirst(5))
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return .unknown }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        // The storage device above the volume says what it is made of.
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        guard let traits = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Device Characteristics" as CFString,
                                                           kCFAllocatorDefault, options) as? [String: Any],
              let medium = traits["Medium Type"] as? String else { return .unknown }
        switch medium {
        case "Solid State": return .solidState
        case "Rotational": return .rotational
        default: return .unknown
        }
    }
}
