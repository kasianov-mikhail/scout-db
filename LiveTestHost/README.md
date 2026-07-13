# Live contract runs

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
2. **Container:** pick a test container identifier (for example
   `iCloud.com.yourname.scoutdb-tests`) and replace
   `iCloud.com.example.scoutdb-tests` in `project.yml` — it appears twice:
   in the entitlement and in the scheme's `SCOUTDB_CONTRACT_CONTAINER`
   environment variable. The container is created on first build.
3. **Signing:** set `DEVELOPMENT_TEAM` in `project.yml` (or generate the
   project, open it in Xcode, and pick your team once under Signing &
   Capabilities).
4. **Generate and run:**

   ```sh
   cd LiveTestHost
   xcodegen generate
   xcodebuild test -project LiveTestHost.xcodeproj -scheme LiveTestHost \
       -destination 'platform=iOS Simulator,name=iPhone 16'
   ```

   For a physical device, use `-destination 'platform=iOS,id=<udid>'`.

## First-run schema bootstrap

The development environment creates record types just-in-time on first write,
but query indexes must be enabled by hand in the
[CloudKit Console](https://icloud.developer.apple.com) → your container →
Schema → Indexes. Expect the first run to fail with "field ... is not marked
queryable"; add the index it names and re-run. The usual starter set on the
`Entity` record type: `entity`, `uuid`, `deleted` (queryable);
`modificationDate` (queryable + sortable); the slot fields the contract
filters and sorts on — `s_00` (queryable), `i_00`, `d_00`, `t_00`
(queryable + sortable). The `Schema` and `Aggregate` record types need
`entity` (queryable) once the registry and views first write them.

Alternatively, generate a management token in the Console and script the
indexes with `cktool` — worthwhile if the schema keeps evolving.

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
