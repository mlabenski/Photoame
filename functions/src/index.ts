import { setGlobalOptions } from "firebase-functions/v2";

setGlobalOptions({ region: "us-central1", maxInstances: 10 });

// Callables
export { createInvite, revokeInvite, acceptInvite } from "./invites";
export { endPair, blockUser } from "./pairs";
export {
  markOpened,
  markReplayed,
  keepSnap,
  reportScreenshot,
  onSnapCreated,
} from "./snaps";
export { submitReport } from "./reports";
export { deleteAccount } from "./account";

// Scheduled
export { sweepExpired } from "./sweep";
