import { getMessaging } from "firebase-admin/messaging";
import { db } from "./common";
import * as logger from "firebase-functions/logger";

/**
 * Send a data+alert push to a single user. The image is NEVER included; the
 * payload only names the sender and identifies the snap so the app can deep-link
 * into the viewer. No-ops safely if the user has no token or when running in the
 * emulator (which has no FCM backend).
 */
export async function sendPushToUser(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>
): Promise<void> {
  const tokenSnap = await db.doc(`users/${uid}/private/push`).get();
  const fcmToken = tokenSnap.get("fcmToken") as string | undefined;
  if (!fcmToken) {
    logger.info(`No fcmToken for ${uid}; skipping push.`);
    return;
  }

  if (process.env.FUNCTIONS_EMULATOR === "true") {
    logger.info(`[emulator] would push to ${uid}: ${title} / ${body}`, data);
    return;
  }

  try {
    await getMessaging().send({
      token: fcmToken,
      notification: { title, body },
      data,
      apns: {
        payload: { aps: { sound: "default", "mutable-content": 1 } },
      },
    });
  } catch (err) {
    logger.warn(`Push to ${uid} failed`, err);
  }
}
