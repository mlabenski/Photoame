import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";
import { HttpsError } from "firebase-functions/v2/https";

if (getApps().length === 0) {
  initializeApp();
}

export const db = getFirestore();
export const bucket = () => getStorage().bucket();
export { FieldValue, Timestamp, HttpsError };

/** Minimal shape of a callable request, so handlers stay unit-testable. */
export interface CallableLike<T = Record<string, unknown>> {
  auth?: { uid: string } | null;
  data: T;
}

export function requireAuth(req: CallableLike<unknown>): string {
  const uid = req.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  return uid;
}

/** Deterministic id from two uids so a pair between A and B is unambiguous. */
export function sortedMembers(a: string, b: string): [string, string] {
  return a < b ? [a, b] : [b, a];
}

export const INVITE_TTL_MS = 24 * 60 * 60 * 1000; // 24 hours
export const COOLDOWN_MS = 24 * 60 * 60 * 1000; // 24 hours
export const REPLAY_WINDOW_MS = 5 * 60 * 1000; // 5 minutes
export const UNOPENED_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

// Unambiguous alphabet (no 0/O/1/I) for spoken invite codes.
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
export function generateInviteCode(length = 6): string {
  let code = "";
  for (let i = 0; i < length; i++) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return code;
}

export interface SnapDoc {
  senderUid: string;
  storagePath: string;
  caption: string;
  timerSeconds: number;
  state: "sent" | "delivered" | "opened" | "replayed" | "kept";
  createdAt: Timestamp;
  openedAt?: Timestamp | null;
  replayedAt?: Timestamp | null;
  keptBy?: string[];
  screenshotAt?: Timestamp | null;
  expiresAt?: Timestamp | null;
}

/** Delete a Storage object; swallow not-found so sweeps are idempotent. */
export async function deleteBlobIfExists(path: string): Promise<void> {
  if (!path) return;
  try {
    await bucket().file(path).delete();
  } catch (err: unknown) {
    const code = (err as { code?: number }).code;
    if (code !== 404) throw err;
  }
}
