# Rules Tests

Security-rules unit tests for Firestore + Storage, run against the Firebase emulator.

## Why this directory exists

`firestore.rules` and `storage.rules` are the authorization spine for the entire app. Every defect in last sprint (PR A-D) lived at a boundary between two internally-consistent surfaces — query vs rule, merged-rules vs deployed-rules. These tests close the **query-vs-rule** half by mechanically proving each predicate refuses the wrong identity.

## Run locally

Requires the Firebase CLI (`npm i -g firebase-tools`) and Java (for the emulator).

```bash
npm install
npm run test:emu
```

`test:emu` boots the firestore + storage emulators on the ports declared in `firebase.json` (8080 / 9199), runs `npm test`, then tears them down.

## Run in CI

`.github/workflows/ci.yml` has a `rules-tests` job that does the same thing on push / PR.

## What's tested

Negative tests (the load-bearing ones):

1. User A cannot read user B's `incoming/{id}`
2. Incoming doc creator cannot escalate `qaStatus` / `status` (those are triage fields)
3. Non-audiologist cannot write `devices/{id}`
4. Storage `incoming/{id}/photos/*` write rejected when caller != `createdBy`
5. Storage `devices/{id}/photos/*` rejected for non-audiologist
6. User cannot self-assign `audiologist` / `admin` on profile create or update

Positive sanity tests confirm the happy path still works (creator reads own doc, audiologist promotes incoming → device, etc.).
