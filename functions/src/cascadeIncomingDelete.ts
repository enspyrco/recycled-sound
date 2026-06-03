import * as functions from "firebase-functions";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";

/**
 * Minimal structural view of the Admin SDK bucket — just the one method the
 * sweep calls. Lets [sweepIncomingStorage] be unit-tested against a fake
 * bucket without standing up the Storage emulator.
 */
export interface SweepableBucket {
  deleteFiles(opts: {prefix: string; force?: boolean}): Promise<unknown>;
}

/**
 * The sweep itself, factored out of the trigger so it's directly callable in
 * tests with a fake [bucket]. Reconciles Storage to a just-deleted
 * `incoming/{id}` doc by recursively removing every object under the prefixes
 * its photos can live in. Best-effort: a prefix that fails to sweep is logged,
 * not thrown — re-running can't restore the already-gone Firestore doc.
 *
 * @param id the deleted doc's id (the `{id}` wildcard).
 * @param data the deleted doc's data (used only to read `createdBy`).
 * @param bucket the Storage bucket to sweep.
 */
export async function sweepIncomingStorage(
  id: string,
  data: Record<string, unknown> | undefined,
  bucket: SweepableBucket
): Promise<void> {
  // Owner uid lives in `createdBy`. Tolerate its absence: a malformed or
  // legacy doc shouldn't strand the uid-independent blobs.
  const createdBy = data?.createdBy;
  const uid = typeof createdBy === "string" ? createdBy : undefined;
  if (!uid) {
    logger.warn(
      `incoming/${id} deleted with no usable createdBy (got ` +
        `${JSON.stringify(createdBy)}); sweeping the uid-independent ` +
        "prefix only. Any scans/{uid}/incoming/ blobs may orphan."
    );
  }

  // Both prefixes a device's photos can live under:
  //   incoming/{id}/                 — where createIncoming actually uploads
  //   scans/{uid}/incoming/{id}/     — what the client delete + capture flow
  //                                    target (uid-scoped)
  // Trailing slash keeps the prefix from matching a sibling like
  // `incoming/{id}-other/`.
  const prefixes = [`incoming/${id}/`];
  if (uid) {
    prefixes.push(`scans/${uid}/incoming/${id}/`);
  }

  // Sweep each prefix independently so one failure can't strand the other.
  // deleteFiles paginates + deletes server-side; force:true keeps it from
  // throwing on the first per-object error so the rest of the batch still
  // clears (we log instead).
  const results = await Promise.allSettled(
    prefixes.map((prefix) => bucket.deleteFiles({prefix, force: true}))
  );

  results.forEach((result, i) => {
    const prefix = prefixes[i];
    if (result.status === "fulfilled") {
      logger.info(`Swept Storage prefix ${prefix} for deleted incoming/${id}`);
    } else {
      // Best-effort: a sweep failure is logged for a follow-up orphan job,
      // not rethrown — the authoritative Firestore doc is already gone and
      // re-running the trigger can't bring it back.
      logger.error(
        `Failed sweeping Storage prefix ${prefix} for incoming/${id}`,
        result.reason
      );
    }
  });
}

/**
 * Server-side authority for cleaning up Storage when an `incoming/{id}`
 * Firestore doc is deleted.
 *
 * **Why this exists.** PR #51 shipped a CLIENT-SIDE delete on the device
 * register: `IncomingDeviceRepository.deleteIncoming` best-effort sweeps the
 * device's photo blobs in Storage, then deletes the `incoming/{id}` Firestore
 * doc. That split is racy by construction — two independent boundaries
 * (Storage + Firestore) flipped from a client that can go offline, lose
 * permission, or be killed mid-sweep. Concretely:
 *
 *   - If the client's Storage sweep partially fails (offline, list throws,
 *     a single blob delete 404s/errors) but the Firestore delete still
 *     succeeds, the blobs orphan — nothing references them and no UI can
 *     surface them for retry.
 *   - The client sweep targets `scans/{uid}/incoming/{id}/`, but
 *     `createIncoming` actually uploads photos to the legacy
 *     `incoming/{id}/photos/` prefix. So for any device created through that
 *     path, the client sweep deletes nothing and every blob orphans even on
 *     the happy path.
 *
 * **What this does.** The Firestore doc is the authoritative half — once it's
 * gone, this trigger fires and reconciles Storage to match via
 * [sweepIncomingStorage], which recursively deletes every object under BOTH
 * prefixes a device's photos can live in. This is the mirror image of
 * `createIncoming`'s rollback intent: there, a failed write compensates by
 * deleting uploaded blobs; here, a successful delete compensates by deleting
 * any blobs the client missed.
 *
 * **uid source.** The deleted doc carries the owner uid in `createdBy` (the
 * same field the `incoming/` security rules pin on create — see
 * `device.dart toFirestore` and `firestore.rules`). There is no `ownerUid`
 * or `uid` field. If it's missing (legacy/garbage doc), the sweep LOGs and
 * still clears the uid-independent `incoming/{id}/` prefix defensively.
 *
 * **Idempotent.** `deleteFiles` on a prefix with no matches is a no-op, so
 * re-delivery of the event (Cloud Functions is at-least-once) is safe.
 */
export const cascadeIncomingDelete = functions.firestore.onDocumentDeleted(
  {document: "incoming/{id}", region: "australia-southeast1"},
  async (event) => {
    await sweepIncomingStorage(
      event.params.id,
      event.data?.data(),
      admin.storage().bucket()
    );
  }
);
