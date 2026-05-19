#!/usr/bin/env node
/**
 * Set a Firebase Auth custom claim `role` for a user, AND mirror it into
 * the user's Firestore profile doc at `users/{uid}.role`.
 *
 * Why two writes: the security rules read `request.auth.token.role` for
 * speed (no extra get() per rule eval). The Firestore copy lets the app
 * read the role without forcing a token refresh, and gives admins a
 * single place to audit roles.
 *
 * Usage:
 *   node scripts/set-user-role.mjs <uid> <role>
 *
 * Roles: donor | recipient | audiologist | admin | anonymous
 *
 * Requires GOOGLE_APPLICATION_CREDENTIALS env var pointing at a service
 * account JSON with Auth Admin + Firestore privileges. Get one from:
 *   Firebase console > Project settings > Service accounts > Generate key
 *
 * After setting a claim, the user must sign out + sign back in for the
 * new token to carry the claim. Or call `User.getIdToken(true)` from the
 * client to force a refresh.
 */
import { getApps, initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';

const VALID = new Set([
  'donor',
  'recipient',
  'audiologist',
  'admin',
  'anonymous',
]);

async function main() {
  const [uid, role] = process.argv.slice(2);
  if (!uid || !role) {
    console.error('Usage: node set-user-role.mjs <uid> <role>');
    process.exit(2);
  }
  if (!VALID.has(role)) {
    console.error(
      `Invalid role "${role}". Expected one of: ${[...VALID].join(', ')}`,
    );
    process.exit(2);
  }
  if (getApps().length === 0) {
    initializeApp({
      credential: applicationDefault(),
      projectId: 'recycled-sound-app',
    });
  }
  const auth = getAuth();
  const firestore = getFirestore();

  await auth.setCustomUserClaims(uid, { role });
  await firestore
    .collection('users')
    .doc(uid)
    .set(
      { role, updatedAt: FieldValue.serverTimestamp() },
      { merge: true },
    );

  console.log(`Set role=${role} for uid=${uid}.`);
  console.log(
    'The user must sign out + back in (or call User.getIdToken(true)) ' +
      'before their JWT carries the new claim.',
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
