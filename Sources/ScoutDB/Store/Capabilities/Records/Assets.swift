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

    private static let stagedFiles = StagedFiles()

    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScoutDBAssets", isDirectory: true)
    }

    static func stage(_ data: Data, limit: Int = maxAssetSize) throws -> RecordValue {
        guard data.count <= limit else { throw SchemaError.invalidValue("asset") }

        let digest = SHA256.hash(data: data).hexString
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let url = stagingDirectory.appendingPathComponent(digest)
        stagedFiles.retain(url)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            stagedFiles.release(url, retiring: false)
            throw error
        }
        return .asset(url)
    }

    static func validateAssetSize(at url: URL, limit: Int = maxAssetSize) throws {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return }
        guard size <= limit else { throw SchemaError.invalidValue("asset") }
    }

    static func discardStagedAssets(in records: [CKRecord]) {
        forEachStagedAsset(in: records) { stagedFiles.release($0, retiring: true) }
    }

    static func abandonStagedAssets(in records: [CKRecord]) {
        forEachStagedAsset(in: records) { stagedFiles.release($0, retiring: false) }
    }

    static func forgetStagedFile(_ url: URL) {
        stagedFiles.forget(url)
    }

    private static func forEachStagedAsset(in records: [CKRecord], _ body: (URL) -> Void) {
        for record in records {
            for key in record.allKeys() {
                guard let asset = record[key] as? CKAsset, let url = asset.fileURL, isStaged(url) else { continue }
                body(url)
            }
        }
    }

    static func isStaged(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(stagingDirectory.standardizedFileURL.path + "/")
    }
}

/// The staged files writes currently hold, counted so that a landed write
/// retires only the files no other in-flight write still points a `CKAsset` at.
///
/// Two writes carrying identical bytes stage into one content-addressed file.
/// The first to land marks it retired and drops its hold; the file goes when
/// the last hold does. A write that never lands drops its hold without
/// retiring the file, leaving the bytes for its retry — and for the sweep, if
/// the retry never comes.
///
private final class StagedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var holds: [String: Int] = [:]
    private var retired: Set<String> = []

    func retain(_ url: URL) {
        lock.withLock { holds[url.standardizedFileURL.path, default: 0] += 1 }
    }

    func release(_ url: URL, retiring: Bool) {
        let path = url.standardizedFileURL.path
        lock.withLock {
            if retiring {
                retired.insert(path)
            }
            let remaining = (holds[path] ?? 0) - 1
            guard remaining <= 0 else {
                holds[path] = remaining
                return
            }
            holds[path] = nil
            guard retired.remove(path) != nil else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.withLock {
            holds[path] = nil
            retired.remove(path)
        }
    }
}

extension EntityStore {
    /// The directory asset bytes are staged into before their write uploads them.
    public static var assetStagingDirectory: URL {
        EntityCoder.stagingDirectory
    }

    /// Deletes staged asset files older than `age` seconds; returns how many.
    ///
    /// A landed write retires the staged files no other in-flight write still
    /// holds, so what accumulates are the orphans of interrupted writes —
    /// staged but never uploaded — plus the copies retained for offline-queued
    /// writes. Pick an `age` comfortably
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
                EntityCoder.forgetStagedFile(file)
                removed += 1
            }
        }
        return removed
    }
}

extension EntityRecord {
    public func assetData(for field: String) throws -> Data? {
        guard case .asset(let url)? = values[field] else { return nil }
        return try Data(contentsOf: url)
    }
}
