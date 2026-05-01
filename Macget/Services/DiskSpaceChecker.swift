import Foundation

enum DiskSpaceChecker {
    /// Free space in bytes available for "important usage" on the volume that
    /// contains `url`. Returns nil if the system can't tell us.
    static func availableBytes(at url: URL) -> Int64? {
        let dirURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        do {
            let values = try dirURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = values.volumeAvailableCapacityForImportantUsage {
                return Int64(bytes)
            }
        } catch {
            // Fall through to legacy key.
        }
        do {
            let values = try dirURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let bytes = values.volumeAvailableCapacity {
                return Int64(bytes)
            }
        } catch {
            // Ignore.
        }
        return nil
    }
}
