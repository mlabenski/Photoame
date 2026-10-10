import { onCall } from "firebase-functions/v2/https";
import { getAuth } from "firebase-admin/auth";
import {
  db,
  HttpsError,
  CallableLike,
  requireAuth,
  deleteBlobIfExists,
} from "./common";
import { teardownPair } from "./pairs";

/**
 * App Store 5.1.1(v) account deletion. Ends any pair, purges the user's docs,
 * their blocks/reports, storage objects, and finally the Auth user.
 */
export async function deleteAccountHandler(
  req: CallableLike<unknown>
): Promise<{ deleted: boolean }> {
  const uid = requireAuth(req);
  const userRef = db.doc(`users/${uid}`);
  const userSnap = await userRef.get();

  // End the active pair first (this deletes shared snaps + blobs for both).
  const activePairId = userSnap.get("activePairId") as string | undefined;
  if (activePairId) {
    await teardownPair(activePairId, uid);
  }

  // Delete any snaps this user still owns in ended pairs, plus their blobs.
  const ownedSnaps = await db
    .collectionGroup("snaps")
    .where("senderUid", "==", uid)
    .get();
  await Promise.all(
    ownedSnaps.docs.map((d) => deleteBlobIfExists(d.get("storagePath") as string))
  );

  // Remove the user's profile picture blob, if any.
  await deleteBlobIfExists(`avatars/${uid}.jpg`);

  const batch = db.batch();
  ownedSnaps.docs.forEach((d) => batch.delete(d.ref));

  // Delete the user's own subcollections (private/push) and block list.
  const priv = await userRef.collection("private").listDocuments();
  priv.forEach((d) => batch.delete(d));
  const blocked = await db.collection(`blocks/${uid}/blocked`).listDocuments();
  blocked.forEach((d) => batch.delete(d));

  // Best-effort: revoke outstanding invites from this user.
  const invites = await db
    .collection("invites")
    .where("fromUid", "==", uid)
    .get();
  invites.docs.forEach((d) => batch.delete(d.ref));

  batch.delete(userRef);
  await batch.commit();

  try {
    await getAuth().deleteUser(uid);
  } catch (err) {
    throw new HttpsError("internal", `Auth user deletion failed: ${String(err)}`);
  }
  return { deleted: true };
}

export const deleteAccount = onCall((req) => deleteAccountHandler(req));
