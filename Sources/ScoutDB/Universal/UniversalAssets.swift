//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CryptoKit
import Foundation

extension UniversalCoder {
    static let maxAssetSize = 50 * 1024 * 1024

    // Content-addressed staging: retries of the same payload reuse the same file,
    // so an interrupted write never leaves a second copy behind.
    static func stage(_ data: Data, limit: Int = maxAssetSize) throws -> RecordValue {
        guard data.count <= limit else { throw UniversalSchemaError.invalidValue("asset") }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UniversalAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(digest)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
        }
        return .asset(url)
    }

    static func validateAssetSize(at url: URL, limit: Int = maxAssetSize) throws {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return }
        guard size <= limit else { throw UniversalSchemaError.invalidValue("asset") }
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
