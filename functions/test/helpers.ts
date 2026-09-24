import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const PROJECT_ID =
  process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "chatsnap-dev";

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  throw new Error(
    "Tests must run against the emulator. Use `npm test` (firebase emulators:exec)."
  );
}

if (getApps().length === 0) {
  initializeApp({ projectId: PROJECT_ID });
}

export const db = getFirestore();

/** Wipe all Firestore data in the emulator between tests. */
export async function clearFirestore(): Promise<void> {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const res = await fetch(
    `http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`,
    { method: "DELETE" }
  );
  if (!res.ok) {
    throw new Error(`Failed to clear Firestore emulator: ${res.status}`);
  }
}

export async function seedUser(
  uid: string,
  fields: Record<string, unknown> = {}
): Promise<void> {
  await db.doc(`users/${uid}`).set({
    displayName: uid,
    activePairId: null,
    cooldowns: {},
    ageConfirmedAt: new Date(),
    createdAt: new Date(),
    ...fields,
  });
}

/** Build a synthetic callable request for a handler under test. */
export function callable<T>(uid: string | null, data: T) {
  return { auth: uid ? { uid } : null, data };
}
