import { describe, it, expect, beforeEach } from "vitest";
import { Timestamp } from "firebase-admin/firestore";
import { db, clearFirestore, seedUser, callable } from "./helpers";
import { endPairHandler } from "../src/pairs";

async function seedActivePair(pairId: string, a: string, b: string) {
  await db.doc(`pairs/${pairId}`).set({
    members: [a, b].sort(),
    status: "active",
    createdAt: Timestamp.now(),
    endedAt: null,
    endedBy: null,
  });
  await seedUser(a, { activePairId: pairId });
  await seedUser(b, { activePairId: pairId });
  // Two snaps with empty storagePath so no blob deletion is attempted.
  for (const snapId of ["s1", "s2"]) {
    await db.doc(`pairs/${pairId}/snaps/${snapId}`).set({
      senderUid: a,
      storagePath: "",
      caption: "",
      timerSeconds: 5,
      state: "delivered",
      createdAt: Timestamp.now(),
    });
  }
}

describe("endPair", () => {
  beforeEach(async () => {
    await clearFirestore();
  });

  it("ends the pair, deletes snaps, clears activePairId, sets 24h cooldown", async () => {
    await seedActivePair("p1", "alice", "bob");
    const res = await endPairHandler(callable("alice", { pairId: "p1" }));
    expect(res.ended).toBe(true);

    const pair = await db.doc("pairs/p1").get();
    expect(pair.get("status")).toBe("ended");
    expect(pair.get("endedBy")).toBe("alice");

    const snaps = await db.collection("pairs/p1/snaps").get();
    expect(snaps.size).toBe(0);

    const alice = await db.doc("users/alice").get();
    const bob = await db.doc("users/bob").get();
    expect(alice.get("activePairId")).toBeNull();
    expect(bob.get("activePairId")).toBeNull();

    const now = Date.now();
    expect((alice.get("cooldowns").bob as Timestamp).toMillis()).toBeGreaterThan(now);
    expect((bob.get("cooldowns").alice as Timestamp).toMillis()).toBeGreaterThan(now);
  });

  it("derives the pair from the caller when no pairId is given", async () => {
    await seedActivePair("p2", "alice", "bob");
    const res = await endPairHandler(callable("bob", {}));
    expect(res.ended).toBe(true);
    expect((await db.doc("pairs/p2").get()).get("status")).toBe("ended");
  });

  it("refuses a non-member", async () => {
    await seedActivePair("p3", "alice", "bob");
    await seedUser("carol");
    await expect(
      endPairHandler(callable("carol", { pairId: "p3" }))
    ).rejects.toThrowError(/not your pair/i);
  });

  it("refuses when the caller is not paired", async () => {
    await seedUser("dave");
    await expect(endPairHandler(callable("dave", {}))).rejects.toThrowError(
      /not paired/i
    );
  });
});
