import Foundation

public enum Secret {
    /// 128 random bits as 32 hex digits, from the system's secure generator:
    /// for passwords that live as long as one sing-box run (its API, the
    /// Wi-Fi login proxy, a server check).
    public static func random() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max, using: &g)) }.joined()
    }
}
