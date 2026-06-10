const assert = require("assert");
const admin = require("firebase-admin");

// END-TO-END test for the cascade sweep — the honest layer the fake-bucket
// unit test (cascadeIncomingDelete.test.js) deliberately can't provide.
//
// The unit test drives `sweepIncomingStorage` against a FAKE bucket that only
// RECORDS deleteFiles({prefix}) calls. That proves the sweep computes the right
// prefixes, but it can NOT prove a real object is actually removed from a real
// bucket — that's the Admin SDK's `deleteFiles` contract, which no fake
// exercises.
//
// This test closes that gap. Against the **Storage + Firestore emulators** it:
//   1. uploads a REAL blob under the canonical intake prefix
//      `captures/{uid}/{id}/photos/0.jpg` (plus blobs under both legacy
//      prefixes the sweep also targets),
//   2. invokes the exported `sweepIncomingStorage` with the REAL emulator
//      bucket (`admin.storage().bucket()`), the same call the deployed
//      `cascadeIncomingDelete` trigger makes on `incoming/{id}` deletion,
//   3. asserts every blob is ACTUALLY GONE afterward (file.exists() === false).
//
// It also asserts the no-uid degraded path leaves uid-scoped blobs intact —
// the honest counterpart to the unit test's prefix-only assertion.
//
// Wiring: this file only runs under `npm run test:emu:storage`, which is
//   firebase emulators:exec --only firestore,storage '<run>'
// so STORAGE_EMULATOR_HOST + FIRESTORE_EMULATOR_HOST are exported into the
// process and the Admin SDK talks to the emulators, not prod. If the Storage
// emulator host isn't set we SKIP rather than silently hit prod.
const {sweepIncomingStorage} = require("../lib/cascadeIncomingDelete");

const PROJECT_ID = "recycled-sound-app";
// The emulator serves whatever bucket name you ask for; pin the canonical one
// so the test is deterministic regardless of ambient config.
const BUCKET_NAME = `${PROJECT_ID}.appspot.com`;

// A 1x1 PNG — a real, non-empty image payload so the upload is a genuine blob,
// not a zero-byte placeholder.
const PNG_1x1 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC",
  "base64"
);

// Guard: refuse to run (skip) unless the Storage emulator is wired in. Without
// this a misconfigured `--only firestore` run would either hit prod Storage or
// hang — both worse than an explicit skip.
const STORAGE_EMU = process.env.STORAGE_EMULATOR_HOST;

let bucket;

(STORAGE_EMU ? describe : describe.skip)(
  "sweepIncomingStorage (E2E against Storage emulator)",
  function () {
    before(function () {
      if (!admin.apps.length) {
        admin.initializeApp({
          projectId: PROJECT_ID,
          storageBucket: BUCKET_NAME,
        });
      }
      bucket = admin.storage().bucket(BUCKET_NAME);
    });

    // Each test seeds its own object names; clear the whole bucket between
    // tests so a leftover blob can't make a later "is gone" assertion lie.
    beforeEach(async function () {
      await bucket.deleteFiles({force: true});
    });

    // Helper: upload a real blob and assert it genuinely landed, so the
    // post-sweep "gone" assertion has a proven baseline to flip from.
    async function seedBlob(objectPath) {
      const file = bucket.file(objectPath);
      await file.save(PNG_1x1, {contentType: "image/png"});
      const [existsBefore] = await file.exists();
      assert.strictEqual(
        existsBefore,
        true,
        `seed failed: ${objectPath} should exist before the sweep`
      );
      return file;
    }

    it("actually deletes a real blob under the canonical captures/ prefix", async function () {
      const uid = "uidABC";
      const id = "devCanonical";
      const file = await seedBlob(`captures/${uid}/${id}/photos/0.jpg`);

      // The exact call the deployed trigger makes, but against the REAL
      // emulator bucket instead of prod.
      await sweepIncomingStorage(id, {createdBy: uid}, bucket);

      const [existsAfter] = await file.exists();
      assert.strictEqual(
        existsAfter,
        false,
        "the canonical-prefix blob must be GONE from the bucket after the sweep"
      );
    });

    it("deletes real blobs under ALL three prefixes (canonical + both legacy)", async function () {
      const uid = "uidABC";
      const id = "devAll";
      const files = await Promise.all([
        seedBlob(`captures/${uid}/${id}/photos/0.jpg`), // canonical
        seedBlob(`scans/${uid}/incoming/${id}/medial.jpg`), // legacy uid-scoped
        seedBlob(`incoming/${id}/photos/lateral.jpg`), // legacy uid-less
      ]);

      await sweepIncomingStorage(id, {createdBy: uid}, bucket);

      const states = await Promise.all(files.map((f) => f.exists()));
      states.forEach(([exists], i) => {
        assert.strictEqual(
          exists,
          false,
          `blob ${files[i].name} must be GONE after the sweep`
        );
      });
    });

    it("leaves a sibling device's blob untouched (prefix isolation)", async function () {
      const uid = "uidABC";
      const target = await seedBlob(`captures/${uid}/devTarget/photos/0.jpg`);
      // Same uid, DIFFERENT device id — the trailing slash in the swept prefix
      // must keep this out of the blast radius.
      const sibling = await seedBlob(`captures/${uid}/devOther/photos/0.jpg`);

      await sweepIncomingStorage("devTarget", {createdBy: uid}, bucket);

      const [targetGone] = await target.exists();
      const [siblingAlive] = await sibling.exists();
      assert.strictEqual(targetGone, false, "target blob must be deleted");
      assert.strictEqual(
        siblingAlive,
        true,
        "a different device's blob must survive — the sweep is prefix-scoped"
      );
    });

    it("with no createdBy, sweeps only the uid-independent prefix and leaves uid-scoped blobs", async function () {
      const id = "devNoUid";
      // This blob lives under the uid-less prefix the degraded path still
      // clears...
      const uidless = await seedBlob(`incoming/${id}/photos/0.jpg`);
      // ...this one is under a uid-scoped prefix the sweep can't compute
      // without createdBy, so it must survive (honest counterpart to the unit
      // test's "only the safe prefix" assertion).
      const uidScoped = await seedBlob(`captures/someUid/${id}/photos/0.jpg`);

      await sweepIncomingStorage(id, {}, bucket);

      const [uidlessGone] = await uidless.exists();
      const [uidScopedAlive] = await uidScoped.exists();
      assert.strictEqual(
        uidlessGone,
        false,
        "the uid-independent blob must be deleted even without createdBy"
      );
      assert.strictEqual(
        uidScopedAlive,
        true,
        "a uid-scoped blob can't be swept without createdBy — it must survive"
      );
    });
  }
);
