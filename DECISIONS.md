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

## Emulator project id
`chatsnap-dev` (see `.firebaserc`). Overridable via `firebase use`.
