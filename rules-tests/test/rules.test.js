const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
} = require('firebase/firestore');
const {
  ref,
  uploadBytes,
  getBytes,
  deleteObject,
} = require('firebase/storage');

const PROJECT_ID = 'recycled-sound-app';

// A 1x1 PNG — smallest valid image payload that satisfies the
// contentType.matches('image/.*') + size predicates in storage.rules.
const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
  'base64'
);
const IMG_META = { contentType: 'image/png' };

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, '../../functions/src/firestore.rules'),
        'utf8'
      ),
    },
    storage: {
      rules: fs.readFileSync(
        path.resolve(__dirname, '../../storage.rules'),
        'utf8'
      ),
    },
  });
});

after(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.clearStorage();
});

// Auth contexts. The Firestore/Storage rules read role from
// request.auth.token.role, which maps to the custom-claim object below.
const asAlice = () => testEnv.authenticatedContext('alice');
const asBob = () => testEnv.authenticatedContext('bob');
const asAudiologist = () =>
  testEnv.authenticatedContext('aud1', { role: 'audiologist' });
const asAdmin = () => testEnv.authenticatedContext('admin1', { role: 'admin' });

// Seed a doc bypassing rules (the analogue of an admin SDK write).
function seed(fn) {
  return testEnv.withSecurityRulesDisabled((ctx) => fn(ctx.firestore()));
}

// Seed a Storage object bypassing rules, so read/delete tests have something
// to act on (the analogue of an Admin SDK upload).
function seedStorage(path) {
  return testEnv.withSecurityRulesDisabled((ctx) =>
    uploadBytes(ref(ctx.storage(), path), PNG_1x1, IMG_META)
  );
}

// A value↔flag-consistent clean device: all seven clinical fields carry real
// values and nothing is flagged. The devices/ rules now reject any write where a
// clinical field is empty/sentinel but not declared in needsInputFields (Bypass
// A, #89), so a clean write MUST be complete. Spread + override for variants.
const CLEAN_DEVICE = {
  brand: 'Oticon',
  model: 'More 1',
  type: 'BTE',
  tubing: 'Slim',
  powerSource: 'Battery',
  batterySize: '13',
  colour: 'Charcoal',
};

describe('Firestore: incoming/', () => {
  it('NEGATIVE: user A cannot read user B\'s incoming doc', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice', brand: 'Phonak' })
    );
    // Bob is neither the creator nor elevated.
    await assertFails(getDoc(doc(asBob().firestore(), 'incoming/inc1')));
  });

  it('POSITIVE: creator can read their own incoming doc', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice', brand: 'Phonak' })
    );
    await assertSucceeds(getDoc(doc(asAlice().firestore(), 'incoming/inc1')));
  });

  it('POSITIVE: audiologist can read any incoming doc', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice', brand: 'Phonak' })
    );
    await assertSucceeds(
      getDoc(doc(asAudiologist().firestore(), 'incoming/inc1'))
    );
  });

  it('NEGATIVE: creator cannot escalate qaStatus (triage field)', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), {
        createdBy: 'alice',
        brand: 'Phonak',
        qaStatus: 'pending',
      })
    );
    await assertFails(
      updateDoc(doc(asAlice().firestore(), 'incoming/inc1'), {
        qaStatus: 'passed',
      })
    );
  });

  it('NEGATIVE: creator cannot set status (triage field)', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice', brand: 'Phonak' })
    );
    await assertFails(
      updateDoc(doc(asAlice().firestore(), 'incoming/inc1'), {
        status: 'ready',
      })
    );
  });

  it('POSITIVE: creator can update an allow-listed field', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice', brand: 'Phonak' })
    );
    await assertSucceeds(
      updateDoc(doc(asAlice().firestore(), 'incoming/inc1'), {
        model: 'Audeo P90',
      })
    );
  });

  it('POSITIVE: audiologist can set qaStatus', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), {
        createdBy: 'alice',
        brand: 'Phonak',
        qaStatus: 'pending',
      })
    );
    await assertSucceeds(
      updateDoc(doc(asAudiologist().firestore(), 'incoming/inc1'), {
        qaStatus: 'passed',
      })
    );
  });

  // #783: the audiologist corrects a scanner-read identity field during review.
  // They're elevated, so the rules let them update freely (the creator allow-list
  // ALSO lists brand/model/type/batterySize, so this never needed a rules change
  // — these assert the editable-identity path is permitted, not blocked).
  it('POSITIVE: audiologist can correct an identity field on an incoming doc',
    async () => {
      await seed((db) =>
        setDoc(doc(db, 'incoming/inc1'), {
          createdBy: 'alice',
          brand: 'Unknown',
          needsInputFields: ['brand'],
        })
      );
      await assertSucceeds(
        updateDoc(doc(asAudiologist().firestore(), 'incoming/inc1'), {
          brand: 'Oticon',
          needsInputFields: [],
        })
      );
    });

  it('POSITIVE: creator can also correct an identity field (allow-listed)',
    async () => {
      await seed((db) =>
        setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice', brand: 'Unknown' })
      );
      await assertSucceeds(
        updateDoc(doc(asAlice().firestore(), 'incoming/inc1'), {
          brand: 'Oticon',
        })
      );
    });

  it('NEGATIVE: create with mismatched createdBy is rejected', async () => {
    await assertFails(
      setDoc(doc(asAlice().firestore(), 'incoming/inc2'), {
        createdBy: 'bob',
      })
    );
  });
});

describe('Firestore: devices/', () => {
  it('NEGATIVE: non-audiologist cannot write devices/', async () => {
    await assertFails(
      setDoc(doc(asAlice().firestore(), 'devices/dev1'), { ...CLEAN_DEVICE })
    );
  });

  it('POSITIVE: audiologist can write a complete (clean) device', async () => {
    await assertSucceeds(
      setDoc(doc(asAudiologist().firestore(), 'devices/dev1'), {
        ...CLEAN_DEVICE,
      })
    );
  });

  it('POSITIVE: any authed user can read devices/', async () => {
    await seed((db) => setDoc(doc(db, 'devices/dev1'), { ...CLEAN_DEVICE }));
    await assertSucceeds(getDoc(doc(asAlice().firestore(), 'devices/dev1')));
  });

  // Trust-boundary gate enforced at the backend (PR #87) — a flagged device
  // cannot be created in devices/ without a self-attributed override, even by
  // an audiologist writing directly (bypassing the client promoteToDevice).
  // The doc is otherwise complete so this isolates the OVERRIDE gate, not the
  // value↔flag consistency check (#89).
  it('NEGATIVE: audiologist cannot create a flagged device without override',
    async () => {
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/flagged'), {
          ...CLEAN_DEVICE,
          tubing: '',
          needsInputFields: ['tubing'],
        })
      );
    });

  it('NEGATIVE: a flagged device with an override attributed to someone ELSE '
    + 'is rejected', async () => {
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/flagged2'), {
          ...CLEAN_DEVICE,
          tubing: '',
          needsInputFields: ['tubing'],
          qaOverride: { overriddenBy: 'someone-else', fields: ['tubing'] },
        })
      );
    });

  it('POSITIVE: a flagged device with a self-attributed override is allowed',
    async () => {
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/flagged3'), {
          ...CLEAN_DEVICE,
          tubing: '',
          needsInputFields: ['tubing'],
          qaOverride: { overriddenBy: 'aud1', fields: ['tubing'] },
        })
      );
    });

  // The side door (Carnot, PR #87 re-review): create clean, then UPDATE to add
  // blockers with no override must be rejected — otherwise the create-only gate
  // is trivially bypassed.
  it('NEGATIVE: cannot update a clean device to add blockers without override',
    async () => {
      await seed((db) => setDoc(doc(db, 'devices/dev9'), { ...CLEAN_DEVICE }));
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/dev9'), {
          tubing: '',
          needsInputFields: ['tubing'],
        })
      );
    });

  it('POSITIVE: servicing edit on an already-overridden device (blockers '
    + 'unchanged) is allowed', async () => {
      await seed((db) => setDoc(doc(db, 'devices/dev10'), {
        ...CLEAN_DEVICE,
        tubing: '',
        needsInputFields: ['tubing'],
        qaOverride: { overriddenBy: 'aud1', fields: ['tubing'] },
      }));
      // A different elevated user edits servicing notes; blocker set untouched.
      await assertSucceeds(
        updateDoc(doc(asAdmin().firestore(), 'devices/dev10'), {
          servicingNotes: 'Re-tubed',
        })
      );
    });

  // Carnot #87 3rd pass: expanding blockers while REUSING the stored override
  // (so the audit under-describes the new blockers) must be rejected.
  it('NEGATIVE: cannot expand blockers reusing the existing override',
    async () => {
      await seed((db) => setDoc(doc(db, 'devices/dev11'), {
        ...CLEAN_DEVICE,
        brand: 'Unknown',
        needsInputFields: ['brand'],
        qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
      }));
      // Same override object, but blockers grow (colour cleared too) — denied.
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/dev11'), {
          colour: '',
          needsInputFields: ['brand', 'colour'],
        })
      );
    });

  it('POSITIVE: expanding blockers WITH a fresh self-attributed override is '
    + 'allowed', async () => {
      await seed((db) => setDoc(doc(db, 'devices/dev12'), {
        ...CLEAN_DEVICE,
        brand: 'Unknown',
        needsInputFields: ['brand'],
        qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
      }));
      await assertSucceeds(
        updateDoc(doc(asAudiologist().firestore(), 'devices/dev12'), {
          colour: '',
          needsInputFields: ['brand', 'colour'],
          qaOverride: { overriddenBy: 'aud1', fields: ['brand', 'colour'] },
        })
      );
    });

  // Clean-write override hygiene (Carnot, PR #92 set-cover 3rd-pass scope note;
  // claude-tasks #821). The flagged path requires a self-attributed, covering
  // override — but the clean (noBlockers) arm used to admit ANY qaOverride, so a
  // direct write could plant a forged/foreign override on a clean doc and
  // pollute an "every device an override touched" audit.
  it('NEGATIVE: a clean device cannot carry a someone-else qaOverride on create',
    async () => {
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/cleanovr1'), {
          ...CLEAN_DEVICE,
          qaOverride: { overriddenBy: 'someone-else', fields: [] },
        })
      );
    });

  it('NEGATIVE: cannot update a clean device to add a someone-else qaOverride',
    async () => {
      await seed((db) => setDoc(doc(db, 'devices/cleanovr2'), { ...CLEAN_DEVICE }));
      // Stays clean (no blockers), but plants a foreign-attributed override.
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/cleanovr2'), {
          qaOverride: { overriddenBy: 'someone-else', fields: [] },
        })
      );
    });

  it('POSITIVE: a clean device may carry a SELF-attributed qaOverride', async () => {
    // The spec is "absent OR self-attributed" — a self-attributed override on a
    // clean doc names the caller and so cannot falsely implicate anyone; allowed.
    await assertSucceeds(
      setDoc(doc(asAudiologist().firestore(), 'devices/cleanovr3'), {
        ...CLEAN_DEVICE,
        qaOverride: { overriddenBy: 'aud1', fields: [] },
      })
    );
  });

  // #783: identity fields (brand/model/type/batterySize) are now editable on the
  // review screen, so a flagged IDENTITY field can be RESOLVED by correcting its
  // value (the flag drops out of needsInputFields) — not only overridden. The
  // boundary gates on the resulting flag set regardless of which field type
  // produced the flag, so these assert the identity path lands on the same gate.
  it('POSITIVE: identity-resolved promotion (brand corrected, no flags) is clean',
    async () => {
      // The audiologist fixed brand → flag set empty → noBlockers() → clean.
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/id1'), {
          ...CLEAN_DEVICE,
          brand: 'Oticon',
          needsInputFields: [],
        })
      );
    });

  it('NEGATIVE: an unresolved IDENTITY flag still needs an override',
    async () => {
      // Same gate as a clinical flag — a leftover brand flag without an override
      // is rejected at the boundary.
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/id2'), {
          ...CLEAN_DEVICE,
          brand: 'Unknown',
          needsInputFields: ['brand'],
        })
      );
    });

  it('POSITIVE: an uncorrected IDENTITY flag promotes WITH a self-override',
    async () => {
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/id3'), {
          ...CLEAN_DEVICE,
          brand: 'Unknown',
          needsInputFields: ['brand'],
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
        })
      );
    });

  // ── Value↔flag consistency: Bypass A, closed (cage-match PR #89) ──────────
  // The gate trusts the client's needsInputFields. Before #89 a client could
  // claim a field resolved (drop it from the set) while its VALUE was still
  // empty/sentinel — sneaking an unresolved field into the register clean, with
  // no override and no audit. These assert the boundary now rejects that.
  it('NEGATIVE: Bypass A — empty identity value with cleared flag is rejected',
    async () => {
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/bypassA1'), {
          ...CLEAN_DEVICE,
          brand: '', // empty, but NOT declared a blocker → inconsistent
          needsInputFields: [],
        })
      );
    });

  it('NEGATIVE: Bypass A — sentinel value with cleared flag is rejected',
    async () => {
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/bypassA2'), {
          ...CLEAN_DEVICE,
          model: 'Unknown', // sentinel, undeclared → inconsistent
          needsInputFields: [],
        })
      );
    });

  it('NEGATIVE: Bypass A — a missing clinical field with no flag is rejected',
    async () => {
      const { colour, ...withoutColour } = CLEAN_DEVICE;
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/bypassA3'), {
          ...withoutColour, // colour absent entirely, undeclared → inconsistent
          needsInputFields: [],
        })
      );
    });

  it('NEGATIVE: Bypass A — update that empties a value without flagging it',
    async () => {
      await seed((db) => setDoc(doc(db, 'devices/bypassA4'), { ...CLEAN_DEVICE }));
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/bypassA4'), {
          colour: '', // cleared but not flagged → inconsistent
        })
      );
    });

  it('NEGATIVE: Bypass A — whitespace-only value with cleared flag is rejected',
    async () => {
      // The UI trims, so '   ' is semantically empty; the rule must agree or a
      // direct write sneaks a blank value past as "resolved" (Carnot #89).
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/bypassA5'), {
          ...CLEAN_DEVICE,
          brand: '   ',
          needsInputFields: [],
        })
      );
    });

  it('NEGATIVE: Bypass A — update to a whitespace-only value without flagging it',
    async () => {
      await seed((db) => setDoc(doc(db, 'devices/bypassA6'), { ...CLEAN_DEVICE }));
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/bypassA6'), {
          colour: '  \t ',
        })
      );
    });

  it('POSITIVE: an empty value IS allowed when properly declared as a blocker '
    + '(consistency, not completeness)', async () => {
      // The rule enforces value↔flag CONSISTENCY, not blanket completeness: an
      // empty field is fine as long as it is declared + overridden.
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/consistent1'), {
          ...CLEAN_DEVICE,
          colour: '',
          needsInputFields: ['colour'],
          qaOverride: { overriddenBy: 'aud1', fields: ['colour'] },
        })
      );
    });

  // ── Override SET-COVER: self-attribution ≠ audit accuracy (#791, Carnot) ───
  // hasSelfAttributedOverride() proves the override names the CALLER, not that it
  // describes WHAT was skipped. A direct write could declare two blockers but stamp
  // an override covering only one — under-describing the promotion it waved through.
  // The gate now requires needsInputFields ⊆ (qaOverride.fields ∪ qaOverride.unrecognised).
  // qaOverride.fields are the same wire strings as the needsInputFields keys
  // (ClinicalField.wire), so the set comparison is apples-to-apples (verified).
  it('NEGATIVE: #791 — override under-describes blockers on CREATE (covers '
    + 'brand only, blockers are brand+colour) is rejected', async () => {
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover1'), {
          ...CLEAN_DEVICE,
          brand: '',
          colour: '',
          needsInputFields: ['brand', 'colour'],
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'] }, // misses colour
        })
      );
    });

  it('POSITIVE: #791 — override exactly covering both blockers is allowed',
    async () => {
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover2'), {
          ...CLEAN_DEVICE,
          brand: '',
          colour: '',
          needsInputFields: ['brand', 'colour'],
          qaOverride: { overriddenBy: 'aud1', fields: ['brand', 'colour'] },
        })
      );
    });

  it('POSITIVE: #791 — a blocker covered via qaOverride.unrecognised is allowed',
    async () => {
      // An unrecognised blocker key (legacy/typo/future) is covered when the
      // override's unrecognised list names it — coverage is over the UNION.
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover3'), {
          ...CLEAN_DEVICE,
          brand: '',
          needsInputFields: ['brand', 'wax_filter'],
          qaOverride: {
            overriddenBy: 'aud1',
            fields: ['brand'],
            unrecognised: ['wax_filter'],
          },
        })
      );
    });

  it('POSITIVE: #791 — an over-covering override (superset of blockers) is '
    + 'allowed', async () => {
      // hasAll is subset, not equality: the override may name more than is flagged.
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover4'), {
          ...CLEAN_DEVICE,
          brand: '',
          needsInputFields: ['brand'],
          qaOverride: { overriddenBy: 'aud1', fields: ['brand', 'colour'] },
        })
      );
    });

  it('NEGATIVE: #791 — a self-attributed but malformed override (no fields/'
    + 'unrecognised keys) does NOT throw and fails coverage → rejected',
    async () => {
      // The override names the caller (passes self-attribution) but lists nothing,
      // so it covers the empty set — every blocker is uncovered. Must deny, not
      // error: the missing-list defaults to [] in overrideCovered().
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover5'), {
          ...CLEAN_DEVICE,
          brand: '',
          needsInputFields: ['brand'],
          qaOverride: { overriddenBy: 'aud1' },
        })
      );
    });

  it('POSITIVE: #791 — a clean device (no blockers) is unaffected by the '
    + 'coverage gate (vacuously satisfied)', async () => {
      // The set-cover predicate is vacuously true when needsInputFields is empty,
      // so the noBlockers path still admits a complete clean device.
      await assertSucceeds(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover6'), {
          ...CLEAN_DEVICE,
          needsInputFields: [],
        })
      );
    });

  it('NEGATIVE: #791 — UPDATE expanding blockers with a FRESH override that '
    + 'under-describes them is rejected', async () => {
      // Carnot #87 stale-override concern, one level up: even a fresh override must
      // COVER the expanded blocker set, not just be renewed and self-attributed.
      await seed((db) => setDoc(doc(db, 'devices/cover7'), {
        ...CLEAN_DEVICE,
        brand: 'Unknown',
        needsInputFields: ['brand'],
        qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
      }));
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/cover7'), {
          colour: '',
          needsInputFields: ['brand', 'colour'],
          // FRESH override (different object) but still only covers brand.
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'], unrecognised: [] },
        })
      );
    });

  it('NEGATIVE: #792 — needsInputFields of a non-list type is rejected by the '
    + 'COVERAGE gate, not incidentally (all values valid)', async () => {
      // Carnot #792 finding #2: an earlier draft returned true for a non-list
      // needsInputFields (wrong polarity → fail-open). Here EVERY clinical value is
      // valid, so valueFlagConsistent() passes and noBlockers() is false (a string's
      // .size() != 0) — the ONLY thing that can reject is the coverage gate. It must.
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover8'), {
          ...CLEAN_DEVICE, // all seven fields carry real values
          needsInputFields: 'brand', // a string, not a list
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
        })
      );
    });

  it('NEGATIVE: #792 — UPDATE that mutates the override to UNDER-COVER while the '
    + 'blocker set is unchanged is rejected (blockersUnchanged arm closed)',
    async () => {
      // Carnot #792 finding #1 (consensus w/ Maxwell): the blockersUnchanged arm
      // previously skipped coverage, so an elevated user could degrade an already-
      // justified override (drop colour) without changing needsInputFields — leaving
      // needsInputFields ⊄ override on the curated register. Coverage is now a
      // top-level conjunct, so the mutation is denied.
      await seed((db) => setDoc(doc(db, 'devices/cover9'), {
        ...CLEAN_DEVICE,
        brand: 'Unknown',
        colour: '',
        needsInputFields: ['brand', 'colour'],
        qaOverride: { overriddenBy: 'aud1', fields: ['brand', 'colour'] },
      }));
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/cover9'), {
          // blocker SET unchanged, but the override now covers only brand.
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
        })
      );
    });

  it('NEGATIVE: #792 — UPDATE forging qaOverride.overriddenBy onto another uid '
    + '(coverage intact, blockers unchanged) is rejected', async () => {
      // Carnot #792 2nd pass: decoupling coverage from attribution left the
      // blockersUnchanged arm able to REWRITE overriddenBy to a victim uid while
      // keeping the blocker set + coverage intact — post-hoc audit attribution
      // forgery. The arm now also requires overrideUnchanged(); a changed override
      // must go through overrideRenewed() (fresh + SELF-attributed), so attributing
      // it to someone else is denied.
      await seed((db) => setDoc(doc(db, 'devices/forge1'), {
        ...CLEAN_DEVICE,
        brand: 'Unknown',
        needsInputFields: ['brand'],
        qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
      }));
      await assertFails(
        updateDoc(doc(asAudiologist().firestore(), 'devices/forge1'), {
          qaOverride: { overriddenBy: 'victim-uid', fields: ['brand'] },
        })
      );
    });

  it('POSITIVE: #792 — an elevated user re-stamping their OWN override (fresh + '
    + 'self-attributed + covering, blockers unchanged) is allowed', async () => {
      // The legitimate counterpart: aud1 restamps its own override (e.g. new
      // timestamp) on an unchanged blocker set. overrideUnchanged() is false, but
      // overrideRenewed() (fresh + self-attributed) + coverage admit it.
      await seed((db) => setDoc(doc(db, 'devices/restamp1'), {
        ...CLEAN_DEVICE,
        brand: 'Unknown',
        needsInputFields: ['brand'],
        qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
      }));
      await assertSucceeds(
        updateDoc(doc(asAudiologist().firestore(), 'devices/restamp1'), {
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'], note: 're-reviewed' },
        })
      );
    });

  it('NEGATIVE: #792 — needsInputFields as a MAP (not a list) with all valid '
    + 'values is rejected by the coverage gate (Kelvin fail-open case)',
    async () => {
      // Kelvin #792: the prior `!(… is list)` disjunct returned true for a Map too,
      // so a Map blocker set sailed through whenever values were valid (a Map passes
      // declaredBlocker()'s `key in` natively, unlike the string which threw). The
      // positive `is list && size==0` structure now sends a Map to the .hasAll()
      // arm, which can't be satisfied over a non-list → deny.
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover11'), {
          ...CLEAN_DEVICE, // every clinical value valid
          needsInputFields: { brand: true, colour: true }, // a Map, not a list
          qaOverride: { overriddenBy: 'aud1', fields: ['brand'] },
        })
      );
    });

  it('NEGATIVE: #792 — a self-attributed override whose fields is the WRONG TYPE '
    + '(not a list) is rejected, not thrown', async () => {
      // Carnot #792 finding #3: overrideFields()/overrideUnrecognised() guard
      // is-list, so a non-list `fields` contributes [] (fails coverage) rather than
      // making .concat() throw. Here fields is a string → covered set is empty →
      // the brand blocker is uncovered → deny.
      await assertFails(
        setDoc(doc(asAudiologist().firestore(), 'devices/cover10'), {
          ...CLEAN_DEVICE,
          brand: '',
          needsInputFields: ['brand'],
          qaOverride: { overriddenBy: 'aud1', fields: 'brand' }, // string, not list
        })
      );
    });
});

describe('Firestore: users/ role self-assignment', () => {
  it('NEGATIVE: user cannot self-create with admin role', async () => {
    await assertFails(
      setDoc(doc(asAlice().firestore(), 'users/alice'), {
        email: 'a@x.com',
        role: 'admin',
      })
    );
  });

  it('POSITIVE: user can self-create with donor role', async () => {
    await assertSucceeds(
      setDoc(doc(asAlice().firestore(), 'users/alice'), {
        email: 'a@x.com',
        role: 'donor',
      })
    );
  });

  it('NEGATIVE: user cannot escalate their own role via update', async () => {
    await seed((db) =>
      setDoc(doc(db, 'users/alice'), { email: 'a@x.com', role: 'donor' })
    );
    await assertFails(
      updateDoc(doc(asAlice().firestore(), 'users/alice'), { role: 'admin' })
    );
  });

  it('POSITIVE: admin can change another user\'s role', async () => {
    await seed((db) =>
      setDoc(doc(db, 'users/alice'), { email: 'a@x.com', role: 'donor' })
    );
    await assertSucceeds(
      updateDoc(doc(asAdmin().firestore(), 'users/alice'), {
        role: 'audiologist',
      })
    );
  });
});

describe('Storage: incoming/{id}/photos', () => {
  it('NEGATIVE: write rejected when caller is not the incoming doc creator', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice' })
    );
    const bobRef = ref(
      asBob().storage(),
      'incoming/inc1/photos/lateral.png'
    );
    await assertFails(uploadBytes(bobRef, PNG_1x1, IMG_META));
  });

  it('POSITIVE: incoming doc creator can upload a photo', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice' })
    );
    const aliceRef = ref(
      asAlice().storage(),
      'incoming/inc1/photos/lateral.png'
    );
    await assertSucceeds(uploadBytes(aliceRef, PNG_1x1, IMG_META));
  });

  it('POSITIVE: audiologist can upload to any incoming photos path', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice' })
    );
    const audRef = ref(
      asAudiologist().storage(),
      'incoming/inc1/photos/lateral.png'
    );
    await assertSucceeds(uploadBytes(audRef, PNG_1x1, IMG_META));
  });

  it('NEGATIVE: non-image content type rejected even for the creator', async () => {
    await seed((db) =>
      setDoc(doc(db, 'incoming/inc1'), { createdBy: 'alice' })
    );
    const aliceRef = ref(asAlice().storage(), 'incoming/inc1/photos/notes.txt');
    await assertFails(
      uploadBytes(aliceRef, Buffer.from('hi'), { contentType: 'text/plain' })
    );
  });
});

describe('Storage: scans/{uid}/ read isolation', () => {
  // In-app capture photos live at scans/{uid}/incoming/{id}/{slot}.jpg. Read
  // must be owner-or-elevated, NOT any-authenticated (that was a cross-user
  // leak of intake photos).
  const scanPath = 'scans/alice/incoming/inc1/medial.jpg';

  it('POSITIVE: owner can read their own scans object', async () => {
    await assertSucceeds(uploadBytes(ref(asAlice().storage(), scanPath), PNG_1x1, IMG_META));
    await assertSucceeds(getBytes(ref(asAlice().storage(), scanPath)));
  });

  it('NEGATIVE: another user cannot read someone else\'s scans object', async () => {
    await assertSucceeds(uploadBytes(ref(asAlice().storage(), scanPath), PNG_1x1, IMG_META));
    await assertFails(getBytes(ref(asBob().storage(), scanPath)));
  });

  it('POSITIVE: audiologist can read any user\'s scans object', async () => {
    await assertSucceeds(uploadBytes(ref(asAlice().storage(), scanPath), PNG_1x1, IMG_META));
    await assertSucceeds(getBytes(ref(asAudiologist().storage(), scanPath)));
  });

  it('NEGATIVE: a different user cannot write into someone else\'s scans prefix', async () => {
    await assertFails(uploadBytes(ref(asBob().storage(), scanPath), PNG_1x1, IMG_META));
  });
});

describe('Storage: devices/{id}/photos', () => {
  it('NEGATIVE: non-audiologist cannot upload device photos', async () => {
    const aliceRef = ref(asAlice().storage(), 'devices/dev1/photos/front.png');
    await assertFails(uploadBytes(aliceRef, PNG_1x1, IMG_META));
  });

  it('POSITIVE: audiologist can upload device photos', async () => {
    const audRef = ref(
      asAudiologist().storage(),
      'devices/dev1/photos/front.png'
    );
    await assertSucceeds(uploadBytes(audRef, PNG_1x1, IMG_META));
  });
});

// Canonical intake bucket: captures/{uid}/{deviceId}/{slot}.jpg. The whole
// point of the uid-outer shape is owner-only access (+ elevated cross-user
// read for triage). These assert the cross-user denial that closes the leak.
describe('Storage: captures/{uid}/**', () => {
  const aliceCapture = 'captures/alice/dev1/0.jpg';

  it('POSITIVE: owner can upload to their own captures path', async () => {
    const aliceRef = ref(asAlice().storage(), aliceCapture);
    await assertSucceeds(uploadBytes(aliceRef, PNG_1x1, IMG_META));
  });

  it('POSITIVE: owner can read their own capture', async () => {
    await seedStorage(aliceCapture);
    await assertSucceeds(getBytes(ref(asAlice().storage(), aliceCapture)));
  });

  it('POSITIVE: owner can delete their own capture', async () => {
    await seedStorage(aliceCapture);
    await assertSucceeds(deleteObject(ref(asAlice().storage(), aliceCapture)));
  });

  it('NEGATIVE: a different uid cannot read another user\'s capture', async () => {
    await seedStorage(aliceCapture);
    // The leak this PR closes: previously `read: if request.auth != null`
    // let any signed-in user read any other user's photos.
    await assertFails(getBytes(ref(asBob().storage(), aliceCapture)));
  });

  it('NEGATIVE: a different uid cannot upload into another user\'s captures path', async () => {
    const bobRef = ref(asBob().storage(), aliceCapture);
    await assertFails(uploadBytes(bobRef, PNG_1x1, IMG_META));
  });

  it('POSITIVE: an audiologist can read another user\'s capture (triage)', async () => {
    await seedStorage(aliceCapture);
    await assertSucceeds(getBytes(ref(asAudiologist().storage(), aliceCapture)));
  });
});

// Hardened transient scan-mode bucket: scans/{uid}/**. Same owner-or-elevated
// read model — assert the cross-user denial that used to be open here too.
describe('Storage: scans/{uid}/** (hardened)', () => {
  const aliceScan = 'scans/alice/123.jpg';

  it('POSITIVE: owner can read their own scan', async () => {
    await seedStorage(aliceScan);
    await assertSucceeds(getBytes(ref(asAlice().storage(), aliceScan)));
  });

  it('NEGATIVE: a different uid cannot read another user\'s scan', async () => {
    await seedStorage(aliceScan);
    await assertFails(getBytes(ref(asBob().storage(), aliceScan)));
  });

  it('POSITIVE: an audiologist can read another user\'s scan (triage)', async () => {
    await seedStorage(aliceScan);
    await assertSucceeds(getBytes(ref(asAudiologist().storage(), aliceScan)));
  });

  it('POSITIVE: owner can delete their own scan', async () => {
    await seedStorage(aliceScan);
    await assertSucceeds(deleteObject(ref(asAlice().storage(), aliceScan)));
  });
});
