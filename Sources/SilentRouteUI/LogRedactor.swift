import Foundation

/// Hides what in a log could identify a user or their servers, for sharing
/// it (in an issue, say): IP addresses, host names, the names they gave
/// profiles, routes and servers (written in “quotes” by the helper), and
/// their account name in paths (/Users/name/…).
enum LogRedactor {
    static func redact(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            (#"(?m)^(# Silent Route session · profile: ).*$"#, "$1‹profile›"),
            (#"“[^”]*”"#, "“‹name›”"),
            (#"/Users/[^/\s:"']+"#, "/Users/‹user›"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "‹ip›"),
            // IPv6: at least three colons, or "::". Times (12:03:09) have two.
            (#"(?i)(?<![0-9a-f:])(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}(?![0-9a-f:])"#, "‹ip›"),
            (#"(?i)(?<![0-9a-f:])(?:[0-9a-f]{1,4}:)*[0-9a-f]{0,4}::(?:[0-9a-f]{1,4}:)*[0-9a-f]{0,4}(?![0-9a-f:])"#, "‹ip›"),
            (#"(?i)\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,63}|xn--[a-z0-9-]+)\b"#, "‹host›"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }
}
