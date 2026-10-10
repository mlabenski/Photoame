# Photoame — agent map

Ephemeral 1:1 photo/video messaging (Snapchat-style) for a *paired* couple.
SwiftUI iOS app + Firebase (Auth, Firestore, Storage, Cloud Functions).
**This file is a router: find the task below, open the 1–2 files named, skip the rest.**

## Golden rules
- **iOS target**: `Photoame/Photoame/`, iOS 18, Swift 6 strict concurrency, **zero warnings**.
- **Backend runs in PROD** (project `photoame-d8adb`); the emulator is dormant. Rules
  take effect only after `firebase deploy` — *merging to main does not deploy them*.
- Media **never** touches the Photos library; kept media lives in the app sandbox only.
- Every snap: client creates it in state `sent`; **all other state transitions are server-side**.
- Deep "why" decisions live in `DECISIONS.md` — read it before changing lifecycle, crypto-ish,
  or orientation/concurrency behavior. Don't duplicate it here.

## Commands
```bash
# iOS build (no signing) — the canonical "does it compile + no warnings" check
xcodebuild build -project Photoame/Photoame.xcodeproj -scheme Photoame \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
# Functions
cd functions && npx tsc --noEmit && npm test        # 21 tests, emulator-backed
# Deploy rules to prod (REQUIRED for any firestore.rules / storage.rules change)
firebase deploy --only firestore:rules,storage --project photoame-d8adb
```

## The snap lifecycle (the core domain)
`sent` → (trigger pushes partner, marks) `delivered` → (recipient opens) `opened`
→ `replayed` (one replay, 5-min window) → `kept` (BOTH tap Keep → permanent).
Unkept snaps expire via `expiresAt`; a scheduled sweep deletes them. A snap carries
a photo or a video (`mediaType`, absent ⇒ photo for old docs).

## Data model — Firestore (`Models/Models.swift` mirrors these)
- `users/{uid}`: displayName, photoURL, activePairId, ageConfirmedAt. `users/{uid}/private/push`: fcmToken.
- `pairs/{pairId}`: members[2], status(active|ended). `pairs/{pairId}/snaps/{snapId}`: Snap.
- `Snap`: senderUid, storagePath, caption, timerSeconds, mediaType?, state, createdAt,
  openedAt?, replayedAt?, keptBy?[], screenshotAt?, expiresAt?.
- Storage: `snaps/{pairId}/{snapId}.{jpg|heic|mp4}`, `avatars/{uid}.jpg`.

## Find-by-task → file
| Task | File(s) |
|---|---|
| Snap doc/blob read-write, send, download | `Services/SnapRepository.swift` |
| Snap/Pair/User structs & enums | `Models/Models.swift` |
| Camera capture (session, zoom, focus, photo + video recording) | `Services/CameraService.swift` |
| Camera UI (shutter tap=photo / hold=video, review panes) | `Camera/CameraView.swift` + `Camera/CameraViewModel.swift` |
| Live preview layer / tap-to-focus mapping | `Camera/CameraPreview.swift` |
| Photo encode/caption burn-in/downscale | `Services/ImageProcessing.swift` |
| Video transcode + **portrait orientation fix** + poster frame | `Services/VideoProcessing.swift` |
| Looping video playback (review, viewer, gallery) | `Components/LoopingPlayerView.swift` |
| Viewing a received snap (timer, replay, screenshot-blur, keep) | `Viewer/ViewerView.swift` + `Viewer/ViewerViewModel.swift` |
| Inbox list / live snap stream / in-app banner | `Inbox/InboxView.swift` + `Inbox/PairSessionViewModel.swift` |
| Kept gallery (local store + grid + video play) | `Gallery/GalleryView.swift` + `Services/KeptStore.swift` |
| Screen bar: settings/partner/gallery/inbox, deep-link to viewer | `App/PairedHomeView.swift` |
| Auth (sign-in, age gate, display name) | `Auth/*` + `Services/AuthService.swift` |
| Pairing / invite codes | `Pairing/*` (client) · `functions/src/invites.ts`, `pairs.ts` |
| Prod↔emulator config, backend toggle | `Services/FirebaseConfig.swift` |
| Push registration (client) | `Services/PushService.swift` |
| Report / block flows | `Safety/ReportSheet.swift` · `functions/src/reports.ts`, `account.ts` |
| App wiring / DI container | `App/PhotoameApp.swift`, `App/AppEnvironment.swift`, `App/RootView.swift` |

## Find-by-task → backend (`functions/src/`)
| Task | File |
|---|---|
| Snap triggers & callables (markOpened/markReplayed/keepSnap/reportScreenshot, onSnapCreated) | `snaps.ts` |
| Push send (FCM; stubbed in emulator) | `push.ts` |
| Expiry sweep | `sweep.ts` |
| Pairing / invites | `pairs.ts`, `invites.ts` |
| Account deletion / block | `account.ts` |
| Shared helpers, constants (REPLAY_WINDOW_MS, TTLs) | `common.ts` |

## Rules & config (root)
`firestore.rules` (snap-create field whitelist incl. `mediaType`) ·
`storage.rules` (image ≤5MB / video ≤60MB) · `firebase.json` · `firestore.indexes.json`.

## Conventions that bite
- Capture session is confined to a serial queue in `CaptureSessionController`
  (`@unchecked Sendable`); the `@MainActor CameraService` only forwards + holds `@Observable` UI state.
- Firestore model structs are **not** `Sendable` (`@DocumentID`); they only cross
  isolation inside `AsyncStream`, which is fine.
- Adding a Snap field means updating BOTH `Models.swift` AND the `hasOnly([...])`
  whitelist in `firestore.rules` (then deploy), or the create is denied.
- New Swift files auto-join the target (Xcode file-system-synchronized group) — no pbxproj edit.
