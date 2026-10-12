/// Silent Route core: the data model, link parser and config generators.
///
/// Everything in this module is pure — no files, no network, no processes —
/// so the code that decides what goes where can be tested exhaustively.
public enum VPNCore {
    /// The sing-box release the generated configs are written for.
    /// Must match `singbox.pin`.
    public static let singBoxVersion = "1.13.16"

    /// sha256 of the extracted sing-box binary per architecture (`uname -m`
    /// naming). Must match `singbox.pin`; the helper refuses any other binary.
    public static let singBoxSHA256: [String: String] = [
        "arm64": "f073b39e01eba314fcf18830646851fb75394956e57b7b3c824968b79d83f656",
        "x86_64": "aaf9dd105855c243b835465625241e06a81b8c377350e5c88250021b16c6e911",
    ]
}
