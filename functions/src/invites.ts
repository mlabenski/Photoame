import { onCall } from "firebase-functions/v2/https";
import {
  db,
  Timestamp,
  HttpsError,
  CallableLike,
  requireAuth,
  sortedMembers,
  generateInviteCode,
  INVITE_TTL_MS,
} from "./common";

/**
 * Create a 6-char invite code, valid 24h, one outstanding at a time.
 * Any prior unused invite from this user is revoked first.
 */
export async function createInviteHandler(
  req: CallableLike<unknown>
): Promise<{ code: string; expiresAt: number }> {
  const uid = requireAuth(req);

  const me = await db.doc(`users/${uid}`).get();
  if (me.get("activePairId")) {
    throw new HttpsError("failed-precondition", "You are already paired.");
  }

  // Revoke any outstanding unused invites from this user.
  const existing = await db
    .collection("invites")
    .where("fromUid", "==", uid)
    .where("usedAt", "==", null)
    .get();
  const batch = db.batch();
  existing.docs.forEach((d) => batch.delete(d.ref));

  // Allocate a fresh, unused code.
  let code = "";
  for (let attempt = 0; attempt < 5; attempt++) {
    const candidate = generateInviteCode();
    const doc = await db.doc(`invites/${candidate}`).get();
    if (!doc.exists) {
      code = candidate;
      break;
    }
  }
  if (!code) {
    throw new HttpsError("internal", "Could not allocate an invite code.");
  }

  const now = Date.now();
  const expiresAt = Timestamp.fromMillis(now + INVITE_TTL_MS);
  batch.set(db.doc(`invites/${code}`), {
    fromUid: uid,
    createdAt: Timestamp.fromMillis(now),
    expiresAt,
    usedAt: null,
  });
  await batch.commit();

  return { code, expiresAt: expiresAt.toMillis() };
}

/** Revoke the caller's outstanding invite(s). */
export async function revokeInviteHandler(
  req: CallableLike<unknown>
): Promise<{ revoked: number }> {
  const uid = requireAuth(req);
  const existing = await db
    .collection("invites")
    .where("fromUid", "==", uid)
    .where("usedAt", "==", null)
    .get();
  const batch = db.batch();
  existing.docs.forEach((d) => batch.delete(d.ref));
  await batch.commit();
  return { revoked: existing.size };
}

/**
 * Accept an invite and form a pair. Runs as a single transaction that fails if
 * either user is already paired, is in cooldown with the other, or has blocked
 * (or been blocked by) the other.
 */
export async function acceptInviteHandler(
  req: CallableLike<{ code?: string }>
): Promise<{ pairId: string; partnerUid: string }> {
  const uid = requireAuth(req);
  const rawCode = req.data?.code;
  if (!rawCode || typeof rawCode !== "string") {
    throw new HttpsError("invalid-argument", "An invite code is required.");
  }
  const code = rawCode.trim().toUpperCase();

  return db.runTransaction(async (tx) => {
    const inviteRef = db.doc(`invites/${code}`);
    const inviteSnap = await tx.get(inviteRef);
    if (!inviteSnap.exists) {
      throw new HttpsError("not-found", "That code is not valid.");
    }
    const invite = inviteSnap.data() as {
      fromUid: string;
      expiresAt: Timestamp;
      usedAt: Timestamp | null;
    };

    if (invite.usedAt) {
      throw new HttpsError("failed-precondition", "That code was already used.");
    }
    if (invite.expiresAt.toMillis() < Date.now()) {
      throw new HttpsError("failed-precondition", "That code has expired.");
    }

    const fromUid = invite.fromUid;
    if (fromUid === uid) {
      throw new HttpsError("failed-precondition", "You cannot pair with yourself.");
    }

    const meRef = db.doc(`users/${uid}`);
    const otherRef = db.doc(`users/${fromUid}`);
    const blockAB = db.doc(`blocks/${uid}/blocked/${fromUid}`);
    const blockBA = db.doc(`blocks/${fromUid}/blocked/${uid}`);

    const [meSnap, otherSnap, blockABSnap, blockBASnap] = await Promise.all([
      tx.get(meRef),
      tx.get(otherRef),
      tx.get(blockAB),
      tx.get(blockBA),
    ]);

    if (!meSnap.exists || !otherSnap.exists) {
      throw new HttpsError("not-found", "User profile missing.");
    }
    if (meSnap.get("activePairId")) {
      throw new HttpsError("failed-precondition", "You are already paired.");
    }
    if (otherSnap.get("activePairId")) {
      throw new HttpsError(
        "failed-precondition",
        "That person is already paired with someone."
      );
    }
    if (blockABSnap.exists || blockBASnap.exists) {
      throw new HttpsError("permission-denied", "Pairing is not allowed.");
    }

    const now = Date.now();
    const myCooldown = (meSnap.get("cooldowns") ?? {})[fromUid] as
      | Timestamp
      | undefined;
    const otherCooldown = (otherSnap.get("cooldowns") ?? {})[uid] as
      | Timestamp
      | undefined;
    if (
      (myCooldown && myCooldown.toMillis() > now) ||
      (otherCooldown && otherCooldown.toMillis() > now)
    ) {
      throw new HttpsError(
        "failed-precondition",
        "You cannot re-pair with this person yet."
      );
    }

    const members = sortedMembers(uid, fromUid);
    const pairRef = db.collection("pairs").doc();
    tx.set(pairRef, {
      members,
      status: "active",
      createdAt: Timestamp.fromMillis(now),
      endedAt: null,
      endedBy: null,
    });
    tx.update(meRef, { activePairId: pairRef.id });
    tx.update(otherRef, { activePairId: pairRef.id });
    tx.update(inviteRef, { usedAt: Timestamp.fromMillis(now) });

    return { pairId: pairRef.id, partnerUid: fromUid };
  });
}

export const createInvite = onCall((req) => createInviteHandler(req));
export const revokeInvite = onCall((req) => revokeInviteHandler(req));
export const acceptInvite = onCall((req) =>
  acceptInviteHandler(req as CallableLike<{ code?: string }>)
);
