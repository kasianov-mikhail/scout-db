//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CloudKit
import CryptoKit
import Foundation

extension EntityCoder {
    static let maxAssetSize = 50 * 1024 * 1024

    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScoutDBAssets", isDirectory: true)
    }

    // Content-addressed staging: retries of the same payload reuse the same file,
    // so an interrupted write never leaves a second copy behind.
    static func stage(_ data: Data, limit: Int = maxAssetSize) throws -> RecordValue {
        guard data.count <= limit else { throw SchemaError.invalidValue("asset") }

        let digest = SHA256.hash(data: data).hexString
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let url = stagingDirectory.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
        }
        return .asset(url)
    }

    static func validateAssetSize(at url: URL, limit: Int = maxAssetSize) throws {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return }
        guard size <= limit else { throw SchemaError.invalidValue("asset") }
    }

    // Deletes the staged files a landed write no longer needs; caller-provided
    // URLs outside the staging directory are theirs to manage. Removal is
    // best-effort: a concurrent write staging identical bytes shares the
    // content-addressed file, and its retry re-stages if the file is gone.
    static func discardStagedAssets(in records: [CKRecord]) {
        for record in records {
            for key in record.allKeys() {
                guard let asset = record[key] as? CKAsset, let url = asset.fileURL, isStaged(url) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func isStaged(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(stagingDirectory.standardizedFileURL.path + "/")
    }
}

extension EntityStore {
    /// The directory asset bytes are staged into before their write uploads them.
    public static var assetStagingDirectory: URL {
        EntityCoder.stagingDirectory
    }

    /// Deletes staged asset files older than `age` seconds; returns how many.
    ///
    /// A landed write retires its own staged files, so what accumulates are the
    /// orphans of interrupted writes — staged but never uploaded — plus the
    /// copies retained for offline-queued writes. Pick an `age` comfortably
    /// longer than any realistic offline stretch, or a queued write could lose
    /// its asset bytes before it flushes.
    ///
    @discardableResult public static func sweepStagedAssets(olderThan age: TimeInterval = 86_400) -> Int {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: EntityCoder.stagingDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return 0 }
        let cutoff = Date(timeIntervalSinceNow: -age)
        var removed = 0
        for file in files {
            guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff else {
                continue
            }
            if (try? manager.removeItem(at: file)) != nil {
                removed += 1
            }
        }
        return removed
    }
}

extension EntityRecord {
    // A downloaded asset URL points into CloudKit's ephemeral cache — read the
    // contents promptly instead of holding on to the URL.
    public func assetData(for field: String) throws -> Data? {
        guard case .asset(let url)? = values[field] else { return nil }
        return try Data(contentsOf: url)
    }
}
