/// Silent Route core: the data model, link parser and config generators.
///
/// Everything in this module is pure — no files, no network, no processes —
/// so the code that decides what goes where can be tested exhaustively.
public enum VPNCore {
    /// The sing-box release the generated configs are written for.
    /// Must match `singbox.pin`.
    public static let singBoxVersion = "1.14.3"

    /// sha256 of the extracted sing-box binary per architecture (`uname -m`
    /// naming). Must match `singbox.pin`; the helper refuses any other binary.
    public static let singBoxSHA256: [String: String] = [
        "arm64": "28b7200074d6380006acc4f035a404c8af3dceb65dd92d7386ed92c9224e08a2",
        "x86_64": "4d63d13fe7516a5d0a76c764095238f9d51ada7bfa5d18cf5030ca3032882c68",
    ]
}
