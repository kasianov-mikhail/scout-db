//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import CryptoKit
import Foundation

public protocol EncryptionKeyProvider: Sendable {
    func key(for keyID: String) throws -> SymmetricKey
}

extension UniversalCoder {
    func seal(_ value: RecordValue, keyID: String?) throws -> RecordValue {
        let plain = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plain, using: key(for: keyID))
        guard let combined = box.combined else { throw UniversalSchemaError.missingKey(keyID ?? "") }
        return .bytes(combined)
    }

    func open(_ value: RecordValue, keyID: String?) throws -> RecordValue {
        guard case .bytes(let data) = value else { throw UniversalSchemaError.invalidValue("ciphertext") }
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key(for: keyID))
        return try JSONDecoder().decode(RecordValue.self, from: plain)
    }

    func surrogate(for canonical: String, keyID: String?) throws -> String {
        let mac = try HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key(for: keyID))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func key(for keyID: String?) throws -> SymmetricKey {
        guard let keyID, let keyProvider else { throw UniversalSchemaError.missingKey(keyID ?? "") }
        return try keyProvider.key(for: keyID)
    }
}
