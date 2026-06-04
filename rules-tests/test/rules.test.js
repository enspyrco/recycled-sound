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
const { ref, uploadBytes, getBytes } = require('firebase/storage');

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
      setDoc(doc(asAlice().firestore(), 'devices/dev1'), { brand: 'Oticon' })
    );
  });

  it('POSITIVE: audiologist can write devices/', async () => {
    await assertSucceeds(
      setDoc(doc(asAudiologist().firestore(), 'devices/dev1'), {
        brand: 'Oticon',
      })
    );
  });

  it('POSITIVE: any authed user can read devices/', async () => {
    await seed((db) => setDoc(doc(db, 'devices/dev1'), { brand: 'Oticon' }));
    await assertSucceeds(getDoc(doc(asAlice().firestore(), 'devices/dev1')));
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
