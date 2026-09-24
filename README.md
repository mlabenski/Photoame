# Chatsnap

Chatsnap is an iPhone photo-messaging app for a couple: each account is paired
with exactly **one** other person, photos arrive by push, are viewed once (plus
one replay) and then disappear unless **both** people choose to keep them.
Chatsnap photos never touch the Photos library.

- **iOS:** Swift 6 · SwiftUI · AVFoundation · iOS 18+ · iPhone-only · portrait-only
- **Backend:** Firebase — Auth (Sign in with Apple only), Firestore, Cloud
  Storage, Cloud Functions (TypeScript / Node 20), Cloud Messaging (APNs)
- **Only third-party dependency in the app:** the Firebase iOS SDK (via SwiftPM)

All product rules live in Cloud Functions. Clients can only edit two fields on
their own profile, manage their push token, and create a snap; every state
transition (open, replay, keep, end pair, delete account, …) is server-side and
enforced again in the security rules.

## Repository layout

```
Chatsnap/                 Xcode project (SwiftUI app)
  Chatsnap/               app sources, feature-foldered
    App/ Auth/ Pairing/ Camera/ Inbox/ Viewer/ Gallery/ Settings/ Services/ Models/
  GoogleService-Info.Sample.plist   copy this to Chatsnap/Chatsnap/GoogleService-Info.plist
functions/                Cloud Functions + emulator-backed tests
seed/                     bot-partner seeder (test the app solo)
firestore.rules  storage.rules  firestore.indexes.json  firebase.json  .firebaserc
DECISIONS.md              ambiguities resolved during the build
```

## 1. Firebase project setup

1. Create a Firebase project (e.g. `chatsnap-dev`) in the
   [Firebase console](https://console.firebase.google.com).
2. Add an **iOS app** with bundle id `com.chatsnap.app`. Download its
   `GoogleService-Info.plist`.
3. Copy it into the app target (this file is git-ignored):
   ```bash
   cp /path/to/GoogleService-Info.plist Chatsnap/Chatsnap/GoogleService-Info.plist
   ```
   For emulator-only work you can instead copy the checked-in sample — the field
   values aren't contacted locally, but a well-formed plist must exist:
   ```bash
   cp Chatsnap/GoogleService-Info.Sample.plist Chatsnap/Chatsnap/GoogleService-Info.plist
   ```
4. In the console enable **Authentication → Sign in with Apple**, create a
   **Firestore** database, and enable **Storage**.
5. Point the CLI at your project id: edit `.firebaserc` or run `firebase use --add`.

### Storage lifecycle backstop

As a safety net, add a bucket lifecycle rule that deletes any object older than
**31 days** (snaps are normally deleted much sooner by `sweepExpired`):

```bash
cat > /tmp/lifecycle.json <<'EOF'
{ "rule": [ { "action": {"type":"Delete"}, "condition": {"age": 31} } ] }
EOF
gsutil lifecycle set /tmp/lifecycle.json gs://<your-bucket>.appspot.com
```

## 2. APNs key upload (push)

1. In the [Apple Developer](https://developer.apple.com) portal → Certificates,
   Identifiers & Profiles → **Keys**, create a key with **Apple Push
   Notifications service (APNs)** enabled. Download the `.p8`.
2. Firebase console → Project settings → **Cloud Messaging** → *Apple app
   configuration* → **APNs Authentication Key**. Upload the `.p8` with its **Key
   ID** and your **Team ID**.
3. The app disables Firebase's method swizzling (`FirebaseAppDelegateProxyEnabled
   = NO`) and forwards the APNs token to FCM in `AppDelegate`.

## 3. Sign in with Apple capability

- The app ships `Chatsnap/Chatsnap/Chatsnap.entitlements` with the
  **Sign in with Apple** entitlement and `aps-environment = development`.
- In Xcode, select the **Chatsnap** target → **Signing & Capabilities**, set your
  **Team**, and confirm both **Sign in with Apple** and **Push Notifications**
  capabilities are present. Automatic signing will register the App ID.
- For a TestFlight/App Store build, the entitlement's `aps-environment` becomes
  `production` automatically during export.

## 4. Running the emulators

Requires the Firebase CLI and a JDK (for the Firestore emulator).

```bash
cd functions && npm install && npm run build && cd ..
firebase emulators:start          # Auth 9099 · Firestore 8080 · Storage 9199
                                  # Functions 5001 · Pub/Sub 8085 · UI 4000
```

In **Debug** builds the app auto-connects to the emulators (see
`Services/FirebaseConfig.swift`). On the Simulator this is `localhost`; on a
physical device set your Mac's LAN IP:

- Xcode → Product → Scheme → Edit Scheme → Run → Arguments → Environment
  Variables → add `CHATSNAP_EMULATOR_HOST = 192.168.x.y`.

### Functions tests

```bash
cd functions
npm test          # boots Firestore/Auth/Storage emulators, runs vitest
```

Covers `acceptInvite`, `endPair`, `keepSnap`, and `sweepExpired` (21 tests).

## 5. Running on a device

1. Open `Chatsnap/Chatsnap.xcodeproj` in Xcode 16 or newer. Let SwiftPM resolve
   the Firebase package (pinned in `Package.resolved` to 11.x).
2. Set your signing **Team** on the Chatsnap target.
3. Ensure `Chatsnap/Chatsnap/GoogleService-Info.plist` exists (step 1).
4. Select your iPhone (iOS 18+) and Run.
   - **Debug** on device: start the emulators and set `CHATSNAP_EMULATOR_HOST`
     to your Mac's IP (both must be on the same Wi-Fi).
   - **Release** on device talks to your production Firebase project and delivers
     real pushes (needs the APNs key from step 2).

### Test the app solo (bot partner)

With the emulators running:

```bash
cd seed && npm install && npm start
```

The seeder creates a **Chatsnap Bot** account and prints an invite code
(`BOTBOT`). In the app, tap **Enter code**, type `BOTBOT`, and you're paired. The
bot then auto-sends a test snap every 60 seconds so you can exercise the viewer,
timers, replay, keep, and expiry with a single device.

## 6. App Review notes

Paste the following into App Store Connect → App Review Information.

> **Sign-in:** Sign in with Apple is the only method. On first launch the app
> shows an 18+ confirmation and asks for a display name.
>
> **Pairing / demo account:** Chatsnap connects two people. To review without a
> second device, we run a **bot partner** on our backend. Use the demo account
> below; it is pre-paired with the bot, which automatically sends a new photo
> every ~60 seconds so you can open, time out, replay, and keep a snap.
>
> - Demo Apple ID: _(provide a sandbox/demo account)_
> - After signing in you are already paired with "Chatsnap Bot".
> - Wait up to a minute for the first snap, tap the inbox pill, then tap the snap
>   to open it. Try **Keep** (the bot keeps automatically, so it lands in the
>   "Us" gallery), and take a screenshot to see the sender notice.
>
> **Photos & privacy:** Photos are captured in memory and uploaded directly; the
> app has **no** Photos-library entitlement and never saves to the camera roll.
> Viewed, un-kept snaps are deleted from the server within ~10 minutes.
>
> **Account deletion (5.1.1(v)):** Settings → **Delete account** ends the pair,
> purges all data and storage, and deletes the Apple sign-in user.
>
> **Safety:** Settings offers **End pair**, **Block** (permanent), and
> **Report**. Blocking/ending deletes all shared content for both users.

## Acceptance criteria → where they're met

| Criterion | Where |
|---|---|
| Two devices pair by code and exchange a photo | `acceptInvite`, camera send, `onSnapCreated` |
| Recipient gets a push within 5s | `onSnapCreated` → FCM/APNs |
| Viewed, un-kept snap gone from Storage ≤10 min | `markOpened` sets `expiresAt`; `sweepExpired` (every 5 min) |
| Third user can't pair with someone paired | `acceptInvite` transaction (clear error) |
| End Pair wipes data + 24h cooldown | `endPair` / `teardownPair` |
| Nothing ever written to Photos | no Photos usage keys; in-memory capture; sandboxed keep store |
| Cold launch to live camera < 1s | camera is the paired home screen; session starts on appear |
