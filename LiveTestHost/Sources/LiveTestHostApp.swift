//
// Copyright 2026 Mikhail Kasianov
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file or at
// https://opensource.org/licenses/MIT.

import SwiftUI

/// The empty shell the live contract tests run inside.
///
/// It exists only to carry the iCloud entitlement and code signature the
/// CloudKit-backed test run needs; nothing in it is exercised directly.
@main
struct LiveTestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("ScoutDB live-contract test host")
                .padding()
        }
    }
}
