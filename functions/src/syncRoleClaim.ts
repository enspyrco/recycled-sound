import * as functions from "firebase-functions";
import * as logger from "firebase-functions/logger";
import * as admin from "firebase-admin";

// Roles that may appear as a custom claim. Mirrors the manual stopgap
// (scripts/set-user-role.mjs) which also recognises "anonymous".
const VALID_ROLES = [
  "donor",
  "recipient",
  "audiologist",
  "admin",
  "anonymous",
] as const;
type Role = (typeof VALID_ROLES)[number];

function isValidRole(value: unknown): value is Role {
  return typeof value === "string" && (VALID_ROLES as readonly string[]).includes(value);
}

/**
 * Keeps the Firebase Auth custom claim `role` in sync with the
 * `users/{uid}.role` Firestore field.
 *
 * Firestore is the source of truth; the custom claim is a derived
 * projection. Security rules read `request.auth.token.role`, so any write
 * that changes the Firestore role WITHOUT updating the claim opens a drift
 * gap — the rules would evaluate against a stale role. The `setUserRole`
 * callable sets both, but direct Firestore writes (web admin, the
 * set-user-role.mjs stopgap, Admin SDK) bypass it. This trigger closes
 * that gap for every write path.
 *
 * onDocumentWritten covers create + update + delete so the self-signup
 * path (a donor/recipient profile created directly in Firestore) also
 * gets a claim, not just admin-driven updates.
 *
 * No infinite-loop risk: setCustomUserClaims does not write Firestore, and
 * the function no-ops when the role field is unchanged.
 */
export const syncRoleClaim = functions.firestore.onDocumentWritten(
  {document: "users/{uid}", region: "australia-southeast1"},
  async (event) => {
    const uid = event.params.uid;
    const before = event.data?.before.data();
    const after = event.data?.after.data();

    const beforeRole = before?.role;
    const afterRole = after?.role;

    // Role field didn't change — nothing to project onto the claim.
    if (beforeRole === afterRole) {
      return;
    }

    // Document deleted (or role removed): clear the claim so a recreated
    // uid doesn't inherit a stale role.
    if (afterRole === undefined) {
      await admin.auth().setCustomUserClaims(uid, null);
      logger.info(`Cleared role claim for ${uid} (role removed)`);
      return;
    }

    if (!isValidRole(afterRole)) {
      logger.warn(
        `users/${uid}.role is "${afterRole}" — not a recognised role; ` +
          "leaving the existing claim untouched."
      );
      return;
    }

    await admin.auth().setCustomUserClaims(uid, {role: afterRole});
    logger.info(`Synced role claim for ${uid}: ${beforeRole ?? "<none>"} -> ${afterRole}`);
  }
);
