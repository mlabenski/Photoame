import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { db, Timestamp, deleteBlobIfExists, UNOPENED_TTL_MS } from "./common";

/**
 * Core sweep logic, exported for tests. Deletes:
 *  - snaps past `expiresAt` that are not kept (viewed-and-abandoned), and
 *  - unopened snaps (sent/delivered) older than 30 days.
 * Returns the number of snaps deleted.
 */
export async function sweepExpiredOnce(now = Date.now()): Promise<number> {
  const nowTs = Timestamp.fromMillis(now);
  const toDelete = new Map<string, { ref: FirebaseFirestore.DocumentReference; path: string }>();

  // 1. Expired (viewed, not kept). Kept snaps have expiresAt cleared, so any doc
  //    with expiresAt <= now is fair game.
  const expired = await db
    .collectionGroup("snaps")
    .where("expiresAt", "<=", nowTs)
    .get();
  for (const d of expired.docs) {
    toDelete.set(d.ref.path, { ref: d.ref, path: d.get("storagePath") as string });
  }

  // 2. Unopened older than 30 days.
  const cutoff = Timestamp.fromMillis(now - UNOPENED_TTL_MS);
  for (const state of ["sent", "delivered"]) {
    const stale = await db
      .collectionGroup("snaps")
      .where("state", "==", state)
      .where("createdAt", "<=", cutoff)
      .get();
    for (const d of stale.docs) {
      toDelete.set(d.ref.path, {
        ref: d.ref,
        path: d.get("storagePath") as string,
      });
    }
  }

  const entries = [...toDelete.values()];
  await Promise.all(entries.map((e) => deleteBlobIfExists(e.path)));

  let batch = db.batch();
  let ops = 0;
  for (const e of entries) {
    batch.delete(e.ref);
    if (++ops >= 400) {
      await batch.commit();
      batch = db.batch();
      ops = 0;
    }
  }
  if (ops > 0) await batch.commit();

  logger.info(`sweepExpired removed ${entries.length} snaps.`);
  return entries.length;
}

export const sweepExpired = onSchedule("every 5 minutes", async () => {
  await sweepExpiredOnce();
});
