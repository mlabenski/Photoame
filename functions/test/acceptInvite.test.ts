import { describe, it, expect, beforeEach } from "vitest";
import { Timestamp } from "firebase-admin/firestore";
import { db, clearFirestore, seedUser, callable } from "./helpers";
import { acceptInviteHandler, createInviteHandler } from "../src/invites";

async function seedInvite(
  code: string,
  fromUid: string,
  opts: { expiresInMs?: number; usedAt?: Timestamp | null } = {}
) {
  await db.doc(`invites/${code}`).set({
    fromUid,
    createdAt: Timestamp.now(),
    expiresAt: Timestamp.fromMillis(Date.now() + (opts.expiresInMs ?? 60_000)),
    usedAt: opts.usedAt ?? null,
  });
}

describe("acceptInvite", () => {
  beforeEach(async () => {
    await clearFirestore();
    await seedUser("alice");
    await seedUser("bob");
  });

  it("pairs two unpaired users and consumes the invite", async () => {
    await seedInvite("ABC234", "alice");
    const res = await acceptInviteHandler(callable("bob", { code: "abc234" }));

    expect(res.pairId).toBeTruthy();
    expect(res.partnerUid).toBe("alice");

    const pair = await db.doc(`pairs/${res.pairId}`).get();
    expect(pair.get("status")).toBe("active");
    expect(pair.get("members").sort()).toEqual(["alice", "bob"]);

    expect((await db.doc("users/alice").get()).get("activePairId")).toBe(res.pairId);
    expect((await db.doc("users/bob").get()).get("activePairId")).toBe(res.pairId);
    expect((await db.doc("invites/ABC234").get()).get("usedAt")).toBeTruthy();
  });

  it("refuses when the accepter is already paired", async () => {
    await seedUser("bob", { activePairId: "existing-pair" });
    await seedInvite("ABC234", "alice");
    await expect(
      acceptInviteHandler(callable("bob", { code: "ABC234" }))
    ).rejects.toThrowError(/already paired/i);
  });

  it("refuses when the inviter is already paired (third-wheel case)", async () => {
    await seedUser("alice", { activePairId: "existing-pair" });
    await seedUser("carol");
    await seedInvite("ABC234", "alice");
    await expect(
      acceptInviteHandler(callable("carol", { code: "ABC234" }))
    ).rejects.toThrowError(/already paired/i);
  });

  it("refuses an expired code", async () => {
    await seedInvite("ABC234", "alice", { expiresInMs: -1000 });
    await expect(
      acceptInviteHandler(callable("bob", { code: "ABC234" }))
    ).rejects.toThrowError(/expired/i);
  });

  it("refuses a used code", async () => {
    await seedInvite("ABC234", "alice", { usedAt: Timestamp.now() });
    await expect(
      acceptInviteHandler(callable("bob", { code: "ABC234" }))
    ).rejects.toThrowError(/already used/i);
  });

  it("refuses during cooldown", async () => {
    await seedUser("bob", {
      cooldowns: { alice: Timestamp.fromMillis(Date.now() + 3_600_000) },
    });
    await seedInvite("ABC234", "alice");
    await expect(
      acceptInviteHandler(callable("bob", { code: "ABC234" }))
    ).rejects.toThrowError(/cannot re-pair/i);
  });

  it("refuses when a block exists in either direction", async () => {
    await db.doc("blocks/alice/blocked/bob").set({ createdAt: Timestamp.now() });
    await seedInvite("ABC234", "alice");
    await expect(
      acceptInviteHandler(callable("bob", { code: "ABC234" }))
    ).rejects.toThrowError(/not allowed/i);
  });

  it("refuses pairing with yourself", async () => {
    await seedInvite("ABC234", "alice");
    await expect(
      acceptInviteHandler(callable("alice", { code: "ABC234" }))
    ).rejects.toThrowError(/yourself/i);
  });

  it("createInvite enforces one outstanding code", async () => {
    const first = await createInviteHandler(callable("alice", {}));
    const second = await createInviteHandler(callable("alice", {}));
    const outstanding = await db
      .collection("invites")
      .where("fromUid", "==", "alice")
      .where("usedAt", "==", null)
      .get();
    expect(outstanding.size).toBe(1);
    expect(outstanding.docs[0].id).toBe(second.code);
    expect(first.code).not.toBe(second.code);
  });
});
