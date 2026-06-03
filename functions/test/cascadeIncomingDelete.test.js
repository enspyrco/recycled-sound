const assert = require("assert");

// Unit test for the cascade's sweep code path. Imports the compiled
// `sweepIncomingStorage` from lib/ (run `npm run build` first) and drives it
// against a FAKE bucket — it records the deleteFiles calls instead of touching
// real Storage.
//
// HONEST SCOPE: this proves the sweep computes the right prefixes and calls
// deleteFiles for each, swallows a per-prefix failure without throwing, and
// degrades gracefully when createdBy is missing. It does NOT prove that
// objects are actually removed from a bucket — that's the Admin SDK's
// contract, exercised by no emulator here. The Storage emulator is not wired
// into this functions test harness (test:emu runs auth,firestore,functions
// only), so an end-to-end "blob is gone" assertion is deliberately out of
// scope. See the trigger doc-comment for the failure modes this closes.
const {sweepIncomingStorage} = require("../lib/cascadeIncomingDelete");

// A fake bucket that records every deleteFiles({prefix}) call. Optionally
// fails for a specific prefix to exercise the best-effort branch.
function fakeBucket({failPrefix} = {}) {
  const calls = [];
  return {
    calls,
    deleteFiles(opts) {
      calls.push(opts);
      if (failPrefix && opts.prefix === failPrefix) {
        return Promise.reject(new Error(`boom: ${opts.prefix}`));
      }
      return Promise.resolve();
    },
  };
}

describe("sweepIncomingStorage", () => {
  it("sweeps both prefixes when createdBy is present, without throwing", async () => {
    const bucket = fakeBucket();
    await sweepIncomingStorage("dev123", {createdBy: "uidABC"}, bucket);

    const prefixes = bucket.calls.map((c) => c.prefix);
    assert.deepStrictEqual(
      prefixes.sort(),
      ["incoming/dev123/", "scans/uidABC/incoming/dev123/"].sort(),
      "should sweep the legacy incoming/ prefix and the uid-scoped scans/ prefix"
    );
    // force:true so a single bad object doesn't abort the batch.
    assert.ok(
      bucket.calls.every((c) => c.force === true),
      "every deleteFiles call should pass force:true"
    );
  });

  it("sweeps only the uid-independent prefix when createdBy is missing", async () => {
    const bucket = fakeBucket();
    await sweepIncomingStorage("dev456", {}, bucket);
    assert.deepStrictEqual(
      bucket.calls.map((c) => c.prefix),
      ["incoming/dev456/"],
      "with no createdBy, only the uid-independent prefix is swept"
    );
  });

  it("tolerates a non-string createdBy and falls back to the safe prefix", async () => {
    const bucket = fakeBucket();
    await sweepIncomingStorage("dev789", {createdBy: 42}, bucket);
    assert.deepStrictEqual(
      bucket.calls.map((c) => c.prefix),
      ["incoming/dev789/"],
      "a garbage createdBy must not produce a scans/42/... prefix"
    );
  });

  it("does not throw when one prefix sweep fails (best-effort)", async () => {
    const bucket = fakeBucket({failPrefix: "incoming/devERR/"});
    // Must resolve, not reject — the authoritative Firestore doc is already
    // gone, so a sweep failure is logged and swallowed.
    await sweepIncomingStorage("devERR", {createdBy: "uidX"}, bucket);
    // The OTHER prefix is still attempted despite the first failing.
    const prefixes = bucket.calls.map((c) => c.prefix).sort();
    assert.deepStrictEqual(
      prefixes,
      ["incoming/devERR/", "scans/uidX/incoming/devERR/"].sort(),
      "a failure on one prefix must not skip the other"
    );
  });

  it("handles undefined doc data without throwing", async () => {
    const bucket = fakeBucket();
    await sweepIncomingStorage("devNull", undefined, bucket);
    assert.deepStrictEqual(bucket.calls.map((c) => c.prefix), ["incoming/devNull/"]);
  });
});
