import Foundation

/// Where "ghost" (temporary) libraries keep their index and thumbnails.
///
/// A ghost is for exploring folders that must leave no trace (private or
/// accounting documents). Its data lives only in a private temporary
/// directory, is deleted when the ghost is closed and when the app quits, and
/// any leftovers of a crashed session are removed at the next launch.
public enum GhostStorage {
    /// Everything ghosts store sits under this directory.
    public static var defaultRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BlazebunnyGhosts", isDirectory: true)
    }

    /// A new private directory (mode 0700) for one ghost library. Pass it as
    /// `base` when opening the `Library`. The name starts with the owning process id,
    /// so another running copy of the app never deletes it as an orphan.
    public static func makeBase(root: URL = defaultRoot, pid: Int32 = getpid()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = root.appendingPathComponent("\(pid)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return base
    }

    /// Deletes one ghost's data. Refuses anything that is not a direct child
    /// of the ghost root, so a bug can never delete a user's folder.
    public static func purge(_ base: URL, root: URL = defaultRoot) {
        guard isChild(base, of: root) else { return }
        try? FileManager.default.removeItem(at: base)
    }

    /// Deletes the data of ghosts whose owning process is gone: leftovers of a crashed
    /// session, at launch. Ghosts of a process that is still running (another copy of the
    /// app, or this one) are kept. Returns how many were removed.
    @discardableResult
    public static func purgeAll(root: URL = defaultRoot, isAlive: (Int32) -> Bool = processIsAlive) -> Int {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for child in children where isChild(child, of: root) {
            if let pid = ownerPID(of: child), isAlive(pid) { continue }
            if (try? fm.removeItem(at: child)) != nil { removed += 1 }
        }
        // Remove the root only when nothing is left in it (never another copy's ghosts).
        if (try? fm.contentsOfDirectory(atPath: root.path))?.isEmpty == true { try? fm.removeItem(at: root) }
        return removed
    }

    static func ownerPID(of base: URL) -> Int32? {
        Int32(base.lastPathComponent.split(separator: "-", maxSplits: 1).first ?? "")
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func isChild(_ url: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(rootPath + "/") && path != rootPath
    }
}
