import { onCall } from "firebase-functions/v2/https";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import {
  db,
  FieldValue,
  Timestamp,
  HttpsError,
  CallableLike,
  requireAuth,
  REPLAY_WINDOW_MS,
} from "./common";
import { sendPushToUser } from "./push";

interface SnapRef {
  pairId?: string;
  snapId?: string;
}

async function loadSnap(uid: string, pairId?: string, snapId?: string) {
  if (!pairId || !snapId) {
    throw new HttpsError("invalid-argument", "pairId and snapId are required.");
  }
  const pairSnap = await db.doc(`pairs/${pairId}`).get();
  const members = (pairSnap.get("members") as string[]) ?? [];
  if (!members.includes(uid)) {
    throw new HttpsError("permission-denied", "Not your pair.");
  }
  const snapRef = db.doc(`pairs/${pairId}/snaps/${snapId}`);
  const snapSnap = await snapRef.get();
  if (!snapSnap.exists) {
    throw new HttpsError("not-found", "Snap not found.");
  }
  return { snapRef, snapSnap, members };
}

/** Recipient opens a snap: set expiresAt = now + 5 min and mark opened. */
export async function markOpenedHandler(
  req: CallableLike<SnapRef>
): Promise<{ expiresAt: number }> {
  const uid = requireAuth(req);
  const { snapRef, snapSnap } = await loadSnap(
    uid,
    req.data?.pairId,
    req.data?.snapId
  );
  if (snapSnap.get("senderUid") === uid) {
    throw new HttpsError("permission-denied", "Senders cannot open their snap.");
  }
  const state = snapSnap.get("state");
  const now = Date.now();
  const expiresAt = Timestamp.fromMillis(now + REPLAY_WINDOW_MS);

  // Idempotent: only set open fields the first time.
  if (state === "sent" || state === "delivered") {
    await snapRef.update({
      state: "opened",
      openedAt: Timestamp.fromMillis(now),
      expiresAt,
    });
    return { expiresAt: expiresAt.toMillis() };
  }
  const existing = snapSnap.get("expiresAt") as Timestamp | null;
  return { expiresAt: existing ? existing.toMillis() : expiresAt.toMillis() };
}

/** Recipient replays once, allowed within the 5-minute window after open. */
export async function markReplayedHandler(
  req: CallableLike<SnapRef>
): Promise<{ replayed: boolean }> {
  const uid = requireAuth(req);
  const { snapRef, snapSnap } = await loadSnap(
    uid,
    req.data?.pairId,
    req.data?.snapId
  );
  if (snapSnap.get("senderUid") === uid) {
    throw new HttpsError("permission-denied", "Senders cannot replay.");
  }
  if (snapSnap.get("state") !== "opened") {
    throw new HttpsError("failed-precondition", "No replay available.");
  }
  const openedAt = snapSnap.get("openedAt") as Timestamp | null;
  if (!openedAt || openedAt.toMillis() + REPLAY_WINDOW_MS < Date.now()) {
    throw new HttpsError("failed-precondition", "Replay window has passed.");
  }
  await snapRef.update({
    state: "replayed",
    replayedAt: Timestamp.now(),
  });
  return { replayed: true };
}

/**
 * Either member marks a snap Keep. Once BOTH are in keptBy the snap becomes
 * permanent: state=kept, expiresAt cleared. Returns whether both have kept.
 */
export async function keepSnapHandler(
  req: CallableLike<SnapRef>
): Promise<{ kept: boolean; bothKept: boolean }> {
  const uid = requireAuth(req);
  return db.runTransaction(async (tx) => {
    const pairId = req.data?.pairId;
    const snapId = req.data?.snapId;
    if (!pairId || !snapId) {
      throw new HttpsError("invalid-argument", "pairId and snapId required.");
    }
    const pairRef = db.doc(`pairs/${pairId}`);
    const snapRef = db.doc(`pairs/${pairId}/snaps/${snapId}`);
    const [pairSnap, snapSnap] = await Promise.all([
      tx.get(pairRef),
      tx.get(snapRef),
    ]);
    const members = (pairSnap.get("members") as string[]) ?? [];
    if (!members.includes(uid)) {
      throw new HttpsError("permission-denied", "Not your pair.");
    }
    if (!snapSnap.exists) {
      throw new HttpsError("not-found", "Snap not found.");
    }

    const keptBy: string[] = snapSnap.get("keptBy") ?? [];
    const nextKeptBy = keptBy.includes(uid) ? keptBy : [...keptBy, uid];
    const bothKept = members.every((m) => nextKeptBy.includes(m));

    tx.update(snapRef, {
      keptBy: nextKeptBy,
      ...(bothKept ? { state: "kept", expiresAt: FieldValue.delete() } : {}),
    });
    return { kept: true, bothKept };
  });
}

/** Recipient took a screenshot: record it and notify the sender. */
export async function reportScreenshotHandler(
  req: CallableLike<SnapRef>
): Promise<{ reported: boolean }> {
  const uid = requireAuth(req);
  const { snapRef, snapSnap } = await loadSnap(
    uid,
    req.data?.pairId,
    req.data?.snapId
  );
  const senderUid = snapSnap.get("senderUid") as string;
  if (senderUid === uid) {
    return { reported: false }; // sender screenshotting their own snap: ignore
  }
  await snapRef.update({ screenshotAt: Timestamp.now() });

  const takerName =
    ((await db.doc(`users/${uid}`).get()).get("displayName") as string) ??
    "Someone";
  await sendPushToUser(
    senderUid,
    "Screenshot",
    `${takerName} took a screenshot.`,
    { type: "screenshot", pairId: req.data?.pairId ?? "", snapId: req.data?.snapId ?? "" }
  );
  return { reported: true };
}

/** On snap creation: validate the sender's pair, push the partner, mark delivered. */
export const onSnapCreated = onDocumentCreated(
  "pairs/{pairId}/snaps/{snapId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const { pairId, snapId } = event.params;
    const senderUid = snap.get("senderUid") as string;

    const pairSnap = await db.doc(`pairs/${pairId}`).get();
    if (!pairSnap.exists || pairSnap.get("status") !== "active") {
      logger.warn(`Snap ${snapId} created in inactive pair ${pairId}; deleting.`);
      await snap.ref.delete();
      return;
    }
    const members = (pairSnap.get("members") as string[]) ?? [];
    if (!members.includes(senderUid)) {
      logger.warn(`Snap ${snapId} sender not in pair; deleting.`);
      await snap.ref.delete();
      return;
    }
    const recipient = members.find((m) => m !== senderUid);
    if (!recipient) return;

    const senderName =
      ((await db.doc(`users/${senderUid}`).get()).get("displayName") as string) ??
      "your partner";

    await sendPushToUser(recipient, "New snap", `New snap from ${senderName}`, {
      type: "snap",
      pairId,
      snapId,
    });

    await snap.ref.update({ state: "delivered" });
  }
);

export const markOpened = onCall((req) =>
  markOpenedHandler(req as CallableLike<SnapRef>)
);
export const markReplayed = onCall((req) =>
  markReplayedHandler(req as CallableLike<SnapRef>)
);
export const keepSnap = onCall((req) =>
  keepSnapHandler(req as CallableLike<SnapRef>)
);
export const reportScreenshot = onCall((req) =>
  reportScreenshotHandler(req as CallableLike<SnapRef>)
);
