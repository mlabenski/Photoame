import { onCall } from "firebase-functions/v2/https";
import {
  db,
  Timestamp,
  HttpsError,
  CallableLike,
  requireAuth,
} from "./common";

interface ReportInput {
  reportedUid?: string;
  pairId?: string | null;
  reason?: string;
  detail?: string;
}

/** Store a report for offline human review. Never auto-acts on the reported user. */
export async function submitReportHandler(
  req: CallableLike<ReportInput>
): Promise<{ reportId: string }> {
  const uid = requireAuth(req);
  const { reportedUid, reason } = req.data ?? {};
  if (!reportedUid || !reason) {
    throw new HttpsError("invalid-argument", "reportedUid and reason required.");
  }
  const ref = db.collection("reports").doc();
  await ref.set({
    reporterUid: uid,
    reportedUid,
    pairId: req.data?.pairId ?? null,
    reason,
    detail: req.data?.detail ?? "",
    createdAt: Timestamp.now(),
  });
  return { reportId: ref.id };
}

export const submitReport = onCall((req) =>
  submitReportHandler(req as CallableLike<ReportInput>)
);
