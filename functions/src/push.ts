import { getMessaging } from "firebase-admin/messaging";
import { db } from "./common";
import * as logger from "firebase-functions/logger";

/**
 * Send a data+alert push to a single user. The snap image is NEVER included; the
 * payload only names the sender and identifies the snap so the app can deep-link
 * into the viewer. An optional `imageUrl` (the sender's small, public avatar) is
 * attached as the notification's thumbnail — the Notification Service Extension
 * fetches it (`mutable-content` is set), and it is also forwarded in `data` so
 * the app can render it in-app. No-ops safely if the user has no token or when
 * running in the emulator (which has no FCM backend).
 */
export async function sendPushToUser(
  uid: string,
  title: string,
  body: string,
  data: Record<string, string>,
  imageUrl?: string
): Promise<void> {
  const tokenSnap = await db.doc(`users/${uid}/private/push`).get();
  const fcmToken = tokenSnap.get("fcmToken") as string | undefined;
  if (!fcmToken) {
    logger.info(`No fcmToken for ${uid}; skipping push.`);
    return;
  }

  // Carry the avatar URL in the data payload too, so the foreground app can show
  // it without re-reading Firestore.
  const payloadData = imageUrl
    ? { ...data, senderPhotoURL: imageUrl }
    : data;

  if (process.env.FUNCTIONS_EMULATOR === "true") {
    logger.info(`[emulator] would push to ${uid}: ${title} / ${body}`, payloadData);
    return;
  }

  try {
    await getMessaging().send({
      token: fcmToken,
      notification: { title, body },
      data: payloadData,
      apns: {
        payload: { aps: { sound: "default", "mutable-content": 1 } },
        ...(imageUrl ? { fcmOptions: { imageUrl } } : {}),
      },
    });
  } catch (err) {
    logger.warn(`Push to ${uid} failed`, err);
  }
}
