import Foundation

/// Free localhost TCP ports, asked of the system together so they differ.
/// Each is free when returned; whoever uses one binds it right after (a
/// sing-box start), and a port taken meanwhile fails that start, whose
/// retry asks again.
public enum LocalPorts {
    public static func free(_ count: Int) -> [UInt16]? {
        var fds: [Int32] = []
        defer { fds.forEach { close($0) } }
        var ports: [UInt16] = []
        for _ in 0..<count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            fds.append(fd)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let ok = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
                }
            }
            guard ok else { return nil }
            ports.append(UInt16(bigEndian: addr.sin_port))
        }
        return ports
    }
}
