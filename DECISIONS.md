# Decisions

Ambiguities resolved during the build, per the working rule: pick the simplest
option consistent with the build prompt, record it here, keep going.

## Snap `state` values
The prompt lists both a create-time value (`state="sent"`) and delivery labels
(Sending, Delivered, Opened, Replayed, Kept, Screenshotted). Resolved to a
lowercase state machine stored on the doc:
`sent -> delivered -> opened -> replayed -> kept | screenshotted`.
- Client creates with `state="sent"` (rules enforce this).
- `onSnapCreated` flips it to `delivered` after queueing the push.
- "Sending" is a client-only UI label shown optimistically before the Firestore
  write confirms; it is never persisted.

## Partner display name
Rather than denormalize names onto the pair doc (the pair schema is fixed by the
prompt), the reader is allowed to read the partner's `users/{uid}` doc when they
share an active pair. Only `displayName` is surfaced in the UI.

## `timerSeconds` encoding
"Until dismissed" is stored as `timerSeconds = 0`. Allowed values: 0, 3, 5, 10.

## Invite codes
6 chars, uppercase, drawn from an unambiguous alphabet (no 0/O/1/I) to make codes
easy to read aloud. Stored as the document id in `invites/{code}`.

## `expiresAt`
Absent until first open. `markOpened` sets `expiresAt = openedAt + 5min`. This is
both the replay window and the sweep deadline for a viewed-but-not-kept snap.
`sweepExpired` also removes unopened snaps older than 30 days.

## Kept storage location
Kept images are copied into `Application Support/KeptSnaps/` in the app sandbox,
with `isExcludedFromBackup` set. Firestore keeps the doc (`state="kept"`), but the
blob is deleted from Cloud Storage once both members have kept it and each client
has downloaded its local copy.

## End Pair / kept-snap purge across the device boundary
The server deletes all snap docs and Storage blobs under a pair on End Pair /
Block / Delete account. It cannot reach kept images already copied into a peer's
sandbox. The client is responsible for purging its local "Us" gallery when it
observes its `activePairId` cleared (pair ended). Recorded so the "all shared
data is gone" criterion is understood as server-side + client-reactive purge.

## Screenshot representation
`reportScreenshot` records `screenshotAt` on the snap and pushes the sender, but
does NOT overwrite `state` (which tracks the open/replay/keep lifecycle). The
sender's inbox shows a "Screenshotted" badge whenever `screenshotAt` is set,
independent of the lifecycle state.

## Firebase project / app identity
Wired to the real project **Photoame** (`photoame-d8adb`, number 1077673205909).
- Bundle id: `com.photoame.app` (matches the registered iOS app + the real
  `GoogleService-Info.plist`).
- Storage bucket: `photoame-d8adb.firebasestorage.app` (new-style default for
  projects created after Oct 2024, not `*.appspot.com`).
- The real `GoogleService-Info.plist` lives at
  `Photoame/Photoame/GoogleService-Info.plist` (git-ignored) so the target
  bundles it; it must sit inside the synchronized source folder, not beside the
  `.xcodeproj`.
- Fully renamed to **Photoame**: the outer folder, `Photoame.xcodeproj`, the
  target/scheme, the `@main` `PhotoameApp`, `Photoame.entitlements`, the source
  folder, and all user-facing copy. The emulator-host / storage-bucket override
  env vars are `PHOTOAME_EMULATOR_HOST` / `PHOTOAME_STORAGE_BUCKET`.

## Info.plist standard keys
`GENERATE_INFOPLIST_FILE = NO` (we ship a custom Info.plist for the Firebase and
camera keys). That means Xcode does NOT auto-inject the standard bundle keys or
apply `INFOPLIST_KEY_*` settings, so `Info.plist` carries `CFBundleIdentifier`,
`CFBundleName`, `CFBundleExecutable`, version keys, etc. via `$(...)` build-setting
variables that expand at build time. Verified the built `.app` reports
`com.photoame.app` / "Photoame".

## Xcode project generation
The project uses an Xcode 16+ file-system-synchronized group
(`PBXFileSystemSynchronizedRootGroup`, objectVersion 77) so new files under
`Photoame/Photoame/` are picked up automatically. `Info.plist` and
`Photoame.entitlements` are excluded from the synchronized target membership via
a build-file exception set (otherwise they'd be double-processed).

## Camera concurrency model
Under Swift 6 strict concurrency the `AVCaptureSession` is confined to a private
serial queue inside `CaptureSessionController` (`@unchecked Sendable`), and the
main-actor `CameraService` only forwards calls and holds `@Observable` UI state.
This keeps the app compiling with **zero warnings** under complete concurrency
checking, which was verified with `xcodebuild` against the iOS Simulator SDK.

## Snap model Sendable
`@DocumentID` is not `Sendable`, so `Snap`/`Pair`/`UserProfile` are not marked
`Sendable`. They only cross isolation inside an `AsyncStream` (which does not
require a `Sendable` element), so this is safe.

## What was NOT verified here
Signing, on-device install, real APNs delivery, and the live end-to-end flow
require an Apple Developer team + a real Firebase project, so they were not run
in this environment. The iOS target compiles clean for the Simulator SDK; the
functions test suite runs green against the emulator.
