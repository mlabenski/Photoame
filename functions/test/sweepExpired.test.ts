import { describe, it, expect, beforeEach } from "vitest";
import { Timestamp } from "firebase-admin/firestore";
import { db, clearFirestore } from "./helpers";
import { sweepExpiredOnce } from "../src/sweep";
import { UNOPENED_TTL_MS } from "../src/common";

const now = Date.now();

async function seedSnap(
  snapId: string,
  fields: Record<string, unknown>
) {
  await db.doc(`pairs/p1/snaps/${snapId}`).set({
    senderUid: "alice",
    storagePath: "", // empty so no blob deletion is attempted
    caption: "",
    timerSeconds: 5,
    ...fields,
  });
}

describe("sweepExpired", () => {
  beforeEach(async () => {
    await clearFirestore();
    await db.doc("pairs/p1").set({
      members: ["alice", "bob"],
      status: "active",
      createdAt: Timestamp.now(),
    });
  });

  it("deletes viewed-and-abandoned snaps past expiresAt", async () => {
    await seedSnap("expired", {
      state: "opened",
      createdAt: Timestamp.fromMillis(now - 600_000),
      openedAt: Timestamp.fromMillis(now - 400_000),
      expiresAt: Timestamp.fromMillis(now - 60_000),
    });
    const deleted = await sweepExpiredOnce(now);
    expect(deleted).toBe(1);
    expect((await db.doc("pairs/p1/snaps/expired").get()).exists).toBe(false);
  });

  it("keeps snaps whose expiresAt is still in the future", async () => {
    await seedSnap("fresh", {
      state: "opened",
      createdAt: Timestamp.fromMillis(now - 10_000),
      openedAt: Timestamp.fromMillis(now - 5_000),
      expiresAt: Timestamp.fromMillis(now + 300_000),
    });
    const deleted = await sweepExpiredOnce(now);
    expect(deleted).toBe(0);
    expect((await db.doc("pairs/p1/snaps/fresh").get()).exists).toBe(true);
  });

  it("never deletes kept snaps (no expiresAt)", async () => {
    await seedSnap("kept", {
      state: "kept",
      createdAt: Timestamp.fromMillis(now - UNOPENED_TTL_MS * 2),
      keptBy: ["alice", "bob"],
      // expiresAt intentionally absent
    });
    const deleted = await sweepExpiredOnce(now);
    expect(deleted).toBe(0);
    expect((await db.doc("pairs/p1/snaps/kept").get()).exists).toBe(true);
  });

  it("deletes unopened snaps older than 30 days", async () => {
    await seedSnap("stale", {
      state: "delivered",
      createdAt: Timestamp.fromMillis(now - UNOPENED_TTL_MS - 60_000),
    });
    await seedSnap("recent", {
      state: "delivered",
      createdAt: Timestamp.fromMillis(now - 60_000),
    });
    const deleted = await sweepExpiredOnce(now);
    expect(deleted).toBe(1);
    expect((await db.doc("pairs/p1/snaps/stale").get()).exists).toBe(false);
    expect((await db.doc("pairs/p1/snaps/recent").get()).exists).toBe(true);
  });
});
