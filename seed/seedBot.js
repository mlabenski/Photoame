/**
 * Photoame bot-partner seeder.
 *
 * Creates a bot account and a fixed invite code, then — once a human user pairs
 * with the bot — auto-sends a test snap every 60 seconds. This lets you exercise
 * the whole app (pairing, push, viewer, expiry, keep) with a single simulator.
 *
 * Run the emulators first (`firebase emulators:start`), then `npm start` here.
 */

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

const PROJECT_ID = process.env.GCLOUD_PROJECT || "photoame-d8adb";
const HOST = process.env.PHOTOAME_EMULATOR_HOST || "localhost";

// Point the Admin SDK at the emulators.
process.env.FIRESTORE_EMULATOR_HOST ||= `${HOST}:8080`;
process.env.FIREBASE_AUTH_EMULATOR_HOST ||= `${HOST}:9099`;
process.env.FIREBASE_STORAGE_EMULATOR_HOST ||= `${HOST}:9199`;

const BOT_UID = "photoame-bot";
const BOT_NAME = "Photoame Bot";
const INVITE_CODE = "BOTBOT";
// New-style default bucket for projects created in/after Oct 2024.
const BUCKET = process.env.PHOTOAME_STORAGE_BUCKET || `${PROJECT_ID}.firebasestorage.app`;
const TIMERS = [3, 5, 10, 0];

admin.initializeApp({ projectId: PROJECT_ID, storageBucket: BUCKET });
const db = admin.firestore();
const auth = admin.auth();
const bucket = admin.storage().bucket();
const { Timestamp } = admin.firestore;

async function ensureBotAccount() {
  try {
    await auth.getUser(BOT_UID);
  } catch {
    await auth.createUser({ uid: BOT_UID, displayName: BOT_NAME });
    console.log(`Created bot auth user ${BOT_UID}`);
  }
  await db.doc(`users/${BOT_UID}`).set(
    {
      displayName: BOT_NAME,
      activePairId: (await db.doc(`users/${BOT_UID}`).get()).get("activePairId") ?? null,
      cooldowns: {},
      ageConfirmedAt: Timestamp.now(),
      createdAt: Timestamp.now(),
    },
    { merge: true }
  );
}

/** Publish a fixed, always-fresh invite the human can type in "Enter code". */
async function ensureInvite() {
  const bot = await db.doc(`users/${BOT_UID}`).get();
  if (bot.get("activePairId")) return; // already paired; no invite needed
  await db.doc(`invites/${INVITE_CODE}`).set({
    fromUid: BOT_UID,
    createdAt: Timestamp.now(),
    expiresAt: Timestamp.fromMillis(Date.now() + 24 * 60 * 60 * 1000),
    usedAt: null,
  });
  console.log(`\n  Pair with the bot: open Photoame, tap "Enter code", type ${INVITE_CODE}\n`);
}

async function sendSnapIfPaired() {
  const bot = await db.doc(`users/${BOT_UID}`).get();
  const pairId = bot.get("activePairId");
  if (!pairId) {
    await ensureInvite();
    return;
  }
  const pair = await db.doc(`pairs/${pairId}`).get();
  if (!pair.exists || pair.get("status") !== "active") return;

  const snapRef = db.collection(`pairs/${pairId}/snaps`).doc();
  const storagePath = `snaps/${pairId}/${snapRef.id}.jpg`;
  const imageBytes = fs.readFileSync(path.join(__dirname, "sample.jpg"));

  await bucket.file(storagePath).save(imageBytes, {
    contentType: "image/jpeg",
    resumable: false,
  });

  const now = new Date();
  const timer = TIMERS[Math.floor(Math.random() * TIMERS.length)];
  await snapRef.set({
    senderUid: BOT_UID,
    storagePath,
    caption: `Bot snap @ ${now.toLocaleTimeString()}`,
    timerSeconds: timer,
    state: "sent",
    createdAt: Timestamp.now(),
  });
  console.log(`Sent snap ${snapRef.id} (timer ${timer || "∞"}s) to pair ${pairId}`);
}

async function main() {
  await ensureBotAccount();
  await ensureInvite();
  console.log("Bot seeder running. Sending a snap every 60s once paired. Ctrl+C to stop.");
  await sendSnapIfPaired();
  setInterval(() => {
    sendSnapIfPaired().catch((err) => console.error("send failed:", err.message));
  }, 60_000);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
