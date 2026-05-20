const assert = require("assert");
const admin = require("firebase-admin");

// firebase emulators:exec injects FIRESTORE_EMULATOR_HOST and
// FIREBASE_AUTH_EMULATOR_HOST; the Admin SDK picks them up automatically.
const PROJECT_ID = "recycled-sound-app";

let app;
let auth;
let db;

before(() => {
  assert.ok(
    process.env.FIRESTORE_EMULATOR_HOST,
    "FIRESTORE_EMULATOR_HOST not set — run via `npm run test:emu`"
  );
  app = admin.initializeApp({projectId: PROJECT_ID});
  auth = admin.auth(app);
  db = admin.firestore(app);
});

after(async () => {
  await app.delete();
});

// Poll the Auth emulator until the user's role claim equals `expected`,
// or fail after `timeoutMs`. The trigger runs asynchronously in the
// functions emulator, so we can't read the claim synchronously.
async function waitForRoleClaim(uid, expected, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    const user = await auth.getUser(uid);
    last = user.customClaims?.role;
    if (last === expected) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  assert.fail(`role claim was "${last}", expected "${expected}" within ${timeoutMs}ms`);
}

describe("syncRoleClaim trigger", () => {
  it("sets the claim when a user doc is created with a role", async () => {
    const uid = `create-${Date.now()}`;
    await auth.createUser({uid});
    await db.collection("users").doc(uid).set({email: "a@x.com", role: "donor"});
    await waitForRoleClaim(uid, "donor");
  });

  it("updates the claim when the Firestore role changes (the drift gap)", async () => {
    const uid = `update-${Date.now()}`;
    await auth.createUser({uid});
    await db.collection("users").doc(uid).set({email: "b@x.com", role: "donor"});
    await waitForRoleClaim(uid, "donor");

    // Direct Firestore write — the path that bypasses the setUserRole
    // callable and used to leave the claim stale.
    await db.collection("users").doc(uid).update({role: "audiologist"});
    await waitForRoleClaim(uid, "audiologist");
  });

  it("clears the claim when the user doc is deleted", async () => {
    const uid = `delete-${Date.now()}`;
    await auth.createUser({uid});
    await db.collection("users").doc(uid).set({email: "c@x.com", role: "admin"});
    await waitForRoleClaim(uid, "admin");

    await db.collection("users").doc(uid).delete();
    // Claim should be cleared (role becomes undefined).
    const deadline = Date.now() + 20000;
    let role = "admin";
    while (Date.now() < deadline) {
      role = (await auth.getUser(uid)).customClaims?.role;
      if (role === undefined) break;
      await new Promise((r) => setTimeout(r, 500));
    }
    assert.strictEqual(role, undefined, "expected role claim to be cleared on delete");
  });

  it("leaves the claim untouched for an unrecognised role value", async () => {
    const uid = `invalid-${Date.now()}`;
    await auth.createUser({uid});
    await db.collection("users").doc(uid).set({email: "d@x.com", role: "donor"});
    await waitForRoleClaim(uid, "donor");

    // Garbage role — trigger should warn and leave the existing claim.
    await db.collection("users").doc(uid).update({role: "wizard"});
    // Give the trigger time to (not) act, then assert claim is still donor.
    await new Promise((r) => setTimeout(r, 3000));
    const role = (await auth.getUser(uid)).customClaims?.role;
    assert.strictEqual(role, "donor", "claim should be unchanged for invalid role");
  });
});
