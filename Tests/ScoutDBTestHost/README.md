# 🧪 Live contract runs

The contract suite in `Tests/ScoutDBTests/Contract` runs against the in-memory
double on every `swift test`. This host runs the **same tests** against a real
CloudKit private database, which is the only way to verify the assumptions the
double encodes (save policies, query semantics, zone deltas, CAS conflicts).

A live run needs a signed app with the iCloud entitlement — unsigned `swift
test` bundles cannot call `CKContainer` at all. This directory holds an
[XcodeGen](https://github.com/yonaskolb/XcodeGen) spec for that host.

## One-time setup

1. **Prerequisites:** Apple Developer Program membership, Xcode 16+,
   `brew install xcodegen`, and a simulator or device signed into iCloud —
   use a dedicated test Apple ID, the suite writes and deletes data.
2. **Container:** `project.yml` is configured for
   `iCloud.dev.kasianov.scoutdb-tests` under team `CGU22629ZT`; to run against
   another container, change it in both places — the entitlement and the
   scheme's `SCOUTDB_CONTRACT_CONTAINER` environment variable.
3. **Signing:** set `DEVELOPMENT_TEAM` in `project.yml` (or generate the
   project, open it in Xcode, and pick your team once under Signing &
   Capabilities).
4. **Generate and run:**

   ```sh
   cd Tests/ScoutDBTestHost
   xcodegen generate
   xcodebuild test -project ScoutDBTestHost.xcodeproj -scheme ScoutDBTestHost \
       -destination 'platform=iOS Simulator,name=iPhone 16'
   ```

   For a physical device, use `-destination 'platform=iOS,id=<udid>'`.

## First-run schema bootstrap

Two one-time steps, both observed on the first real run:

1. **Container creation.** `xcodebuild -allowProvisioningUpdates` registers
   the App ID but does not create the CloudKit container — every call fails
   with "Bad Container" (CKError 1014) until it exists. Open the generated
   project once in Xcode → target ScoutDBTestHost → Signing & Capabilities →
   press the refresh button under the iCloud container list (or create the
   identifier on the developer portal).
2. **The `___modTime` index.** The development environment creates record
   types and marks user fields queryable just-in-time, but system fields get
   no indexes, and `changes(since:)` queries `modificationDate`. `cktool`
   authenticates through the local Xcode session — no management token needed:

   ```sh
   xcrun cktool export-schema --team-id <team> \
       --container-id <container> --environment development > schema.ckdb
   # In RECORD TYPE Entity: "___modTime" TIMESTAMP QUERYABLE SORTABLE,
   xcrun cktool import-schema --team-id <team> \
       --container-id <container> --environment development --file schema.ckdb
   ```

## What to expect

- The suite polls (`eventually`) instead of asserting immediate consistency —
  freshly written records reach the query indexes with a lag of seconds, so a
  live run takes minutes, not the double's milliseconds.
- Every run is hermetic: a run-salted private zone plus run-salted entity
  names; teardown deletes the zone and retires the schemas. Leftover
  `Aggregate` grid rows and retired `Schema` rows may accumulate in the
  development environment — reset it from the Console when it gets noisy.
- One test (`staleConditionalSave`) is live-only by design: the in-memory
  double accepts every conditional save today, and the live run exists to keep
  that divergence visible.
- This does not run in GitHub Actions: the runner has no signed-in iCloud
  account. Live runs stay local (or on a self-hosted runner with a logged-in
  simulator).
