import { describe, it, expect, beforeEach } from "vitest";
import { Timestamp } from "firebase-admin/firestore";
import { db, clearFirestore, callable } from "./helpers";
import { keepSnapHandler } from "../src/snaps";

async function seedPairWithSnap() {
  await db.doc("pairs/p1").set({
    members: ["alice", "bob"],
    status: "active",
    createdAt: Timestamp.now(),
    endedAt: null,
    endedBy: null,
  });
  await db.doc("pairs/p1/snaps/s1").set({
    senderUid: "alice",
    storagePath: "snaps/p1/s1.jpg",
    caption: "",
    timerSeconds: 5,
    state: "opened",
    createdAt: Timestamp.now(),
    openedAt: Timestamp.now(),
    keptBy: [],
    expiresAt: Timestamp.fromMillis(Date.now() + 300_000),
  });
}

describe("keepSnap", () => {
  beforeEach(async () => {
    await clearFirestore();
    await seedPairWithSnap();
  });

  it("does not become permanent until BOTH members keep", async () => {
    const first = await keepSnapHandler(callable("alice", { pairId: "p1", snapId: "s1" }));
    expect(first.bothKept).toBe(false);

    const snap = await db.doc("pairs/p1/snaps/s1").get();
    expect(snap.get("keptBy")).toEqual(["alice"]);
    expect(snap.get("state")).toBe("opened");
    expect(snap.get("expiresAt")).not.toBeNull();
  });

  it("becomes kept and clears expiresAt once both keep", async () => {
    await keepSnapHandler(callable("alice", { pairId: "p1", snapId: "s1" }));
    const second = await keepSnapHandler(callable("bob", { pairId: "p1", snapId: "s1" }));
    expect(second.bothKept).toBe(true);

    const snap = await db.doc("pairs/p1/snaps/s1").get();
    expect(snap.get("keptBy").sort()).toEqual(["alice", "bob"]);
    expect(snap.get("state")).toBe("kept");
    expect(snap.get("expiresAt")).toBeUndefined();
  });

  it("is idempotent for a repeated keep by the same member", async () => {
    await keepSnapHandler(callable("alice", { pairId: "p1", snapId: "s1" }));
    const again = await keepSnapHandler(callable("alice", { pairId: "p1", snapId: "s1" }));
    expect(again.bothKept).toBe(false);
    const snap = await db.doc("pairs/p1/snaps/s1").get();
    expect(snap.get("keptBy")).toEqual(["alice"]);
  });

  it("refuses a non-member", async () => {
    await expect(
      keepSnapHandler(callable("carol", { pairId: "p1", snapId: "s1" }))
    ).rejects.toThrowError(/not your pair/i);
  });
});
