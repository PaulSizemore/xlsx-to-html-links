import Foundation

public enum RawFormats {
    /// Lowercased extensions treated as RAW originals.
    public static let extensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff",
        "gpr", "iiq", "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf",
        "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    ]

    public static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    public static let sidecarExtension = "xmp"

    public static func isRaw(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
