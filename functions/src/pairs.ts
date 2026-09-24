import { onCall } from "firebase-functions/v2/https";
import {
  db,
  Timestamp,
  HttpsError,
  CallableLike,
  requireAuth,
  deleteBlobIfExists,
  COOLDOWN_MS,
} from "./common";

/**
 * Delete every snap doc + blob under a pair and mark the pair ended. Optionally
 * applies a cooldown between the two members. Safe to call on an already-ended
 * pair. Returns the pair's members.
 */
export async function teardownPair(
  pairId: string,
  endedBy: string,
  opts: { cooldownMs?: number } = {}
): Promise<string[]> {
  const pairRef = db.doc(`pairs/${pairId}`);
  const pairSnap = await pairRef.get();
  if (!pairSnap.exists) return [];
  const members = (pairSnap.get("members") as string[]) ?? [];

  // Delete all snap blobs, then all snap docs.
  const snaps = await pairRef.collection("snaps").get();
  await Promise.all(
    snaps.docs.map((d) => deleteBlobIfExists(d.get("storagePath") as string))
  );
  let batch = db.batch();
  let ops = 0;
  for (const d of snaps.docs) {
    batch.delete(d.ref);
    if (++ops >= 400) {
      await batch.commit();
      batch = db.batch();
      ops = 0;
    }
  }

  const now = Date.now();
  batch.update(pairRef, {
    status: "ended",
    endedAt: Timestamp.fromMillis(now),
    endedBy,
  });

  // Clear activePairId and (optionally) set a cooldown on both users.
  if (members.length === 2) {
    const [a, b] = members;
    const cooldown = opts.cooldownMs;
    batch.set(
      db.doc(`users/${a}`),
      {
        activePairId: null,
        ...(cooldown
          ? { cooldowns: { [b]: Timestamp.fromMillis(now + cooldown) } }
          : {}),
      },
      { merge: true }
    );
    batch.set(
      db.doc(`users/${b}`),
      {
        activePairId: null,
        ...(cooldown
          ? { cooldowns: { [a]: Timestamp.fromMillis(now + cooldown) } }
          : {}),
      },
      { merge: true }
    );
  }
  await batch.commit();
  return members;
}

export async function endPairHandler(
  req: CallableLike<{ pairId?: string }>
): Promise<{ ended: boolean }> {
  const uid = requireAuth(req);
  const pairId =
    req.data?.pairId ??
    ((await db.doc(`users/${uid}`).get()).get("activePairId") as
      | string
      | undefined);
  if (!pairId) {
    throw new HttpsError("failed-precondition", "You are not paired.");
  }
  const pairSnap = await db.doc(`pairs/${pairId}`).get();
  if (!pairSnap.exists || !(pairSnap.get("members") as string[]).includes(uid)) {
    throw new HttpsError("permission-denied", "Not your pair.");
  }
  await teardownPair(pairId, uid, { cooldownMs: COOLDOWN_MS });
  return { ended: true };
}

/**
 * Block another user permanently and tear down any pair with them. The block
 * record is what makes it permanent (acceptInvite refuses on any block record);
 * a cooldown is also applied as a belt-and-suspenders measure.
 */
export async function blockUserHandler(
  req: CallableLike<{ otherUid?: string }>
): Promise<{ blocked: boolean }> {
  const uid = requireAuth(req);
  const otherUid = req.data?.otherUid;
  if (!otherUid || typeof otherUid !== "string") {
    throw new HttpsError("invalid-argument", "otherUid is required.");
  }

  await db.doc(`blocks/${uid}/blocked/${otherUid}`).set({
    createdAt: Timestamp.now(),
  });

  const activePairId = (await db.doc(`users/${uid}`).get()).get(
    "activePairId"
  ) as string | undefined;
  if (activePairId) {
    const members = (await db.doc(`pairs/${activePairId}`).get()).get(
      "members"
    ) as string[] | undefined;
    if (members?.includes(otherUid)) {
      await teardownPair(activePairId, uid, { cooldownMs: COOLDOWN_MS });
    }
  }
  return { blocked: true };
}

export const endPair = onCall((req) =>
  endPairHandler(req as CallableLike<{ pairId?: string }>)
);
export const blockUser = onCall((req) =>
  blockUserHandler(req as CallableLike<{ otherUid?: string }>)
);
