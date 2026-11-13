import Foundation
import VPNCore

/// Removal inside a folder a user controls, by descriptor only.
public enum SafeRemove {
    /// `home/Library/Logs/Silent Route`, if every folder on the way is a
    /// real folder owned by `uid`.
    public static func userLogs(home: String, uid: uid_t) {
        var fd = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        for name in ["Library", "Logs"] {
            guard owned(fd, by: uid) else { close(fd); return }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return }
            fd = next
        }
        defer { close(fd) }
        guard owned(fd, by: uid) else { return }
        tree(in: fd, SessionLogFormat.base.last ?? "Silent Route")
    }

    /// Removes `name` inside the folder `parent`: a file or a link is
    /// unlinked (never followed), a folder emptied the same way first.
    public static func tree(in parent: Int32, _ name: String, depth: Int = 0) {
        guard depth < 16 else { return }
        if unlinkat(parent, name, 0) == 0 { return }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        let copy = dup(fd)
        if copy >= 0, let d = fdopendir(copy) {
            var names: [String] = []
            while let e = readdir(d) {
                let len = Int(e.pointee.d_namlen)
                let n = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(len), as: UTF8.self) }
                if n != "." && n != ".." { names.append(n) }
            }
            closedir(d)
            for n in names { tree(in: fd, n, depth: depth + 1) }
        } else if copy >= 0 {
            close(copy)
        }
        close(fd)
        unlinkat(parent, name, AT_REMOVEDIR)
    }

    /// The open descriptor is a folder (not a link: opened with
    /// O_NOFOLLOW) that belongs to `uid`.
    static func owned(_ fd: Int32, by uid: uid_t) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == uid
    }
}
