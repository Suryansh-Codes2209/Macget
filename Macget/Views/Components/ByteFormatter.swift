import Foundation

enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        f.includesUnit = true
        f.includesCount = true
        return f
    }()

    static func string(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return formatter.string(fromByteCount: bytes)
    }

    static func speedString(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "—" }
        let s = formatter.string(fromByteCount: Int64(bytesPerSec))
        return "\(s)/s"
    }

    static func etaString(_ seconds: TimeInterval?) -> String {
        guard let s = seconds, s.isFinite, s >= 0 else { return "—" }
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }
}
