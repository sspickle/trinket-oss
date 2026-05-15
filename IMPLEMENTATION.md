# Trinket Firestore Adapter — Implementation Log

## Architecture decision

**Option A**: Firestore backend translates MongoDB-style query syntax internally.
Existing class methods in all model files are unchanged. The backend factory
selects the adapter at boot time via `config.db.backend`.

## What's been committed

### Slice 1 — Backend factory scaffold (commit d754216)
- `lib/db/backend-factory.js` — singleton that returns `mongoose-backend` or
  `firestore-backend` based on `config.db.backend` ('mongoose' is default)
- `lib/db/mongoose-backend.js` — thin pass-through to `mongoose.model()`
- `lib/models/model.js` — changed one line: `mongoose.model(...)` →
  `backend.getBackend().createModel(...)`
- `config/test.yaml` — added `redis.enabled: false` (uses in-memory fallback)
- Deleted `test/helpers/catbox-redis.js` (obsolete — sessions use catbox-mongoose)

### Slice 2 — Full Firestore adapter (commit ba89014)
- `lib/db/firestore-backend.js` — complete implementation
- `package.json` / `package-lock.json` — `@google-cloud/firestore@8.6.0` added

## What the Firestore adapter supports

**Query translation** (MongoDB syntax → Firestore):
- `{ field: value }` → equality `==`
- `{ field: { $ne: v } }` → `!=`
- `{ field: { $in: [...] } }` → `in`
- `{ field: { $gt/$lt/$gte/$lte: v } }` → range comparisons
- `{ field: { $exists: true/false } }` → `!= null` / `== null`
- `{ $or: [...] }` → `Filter.or()` (Firestore Native mode only)

**Update translation**:
- `{ $set: { f: v } }` → field update
- `{ $inc: { f: n } }` → `FieldValue.increment(n)`
- `{ $push: { f: v } }` → `FieldValue.arrayUnion(v)`
- `{ $push: { f: { $each: [...] } } }` → `FieldValue.arrayUnion(...values)`
- `{ $pull: { f: v } }` → `FieldValue.arrayRemove(v)`
- `{ $addToSet: { f: v } }` → `FieldValue.arrayUnion(v)`

**Mongoose-compatible API surface**:
- `Model.find(filter).sort().limit().skip().exec()`
- `Model.findOne(filter)`, `Model.findById(id)`
- `Model.findByIdAndUpdate(id, update, options)`
- `Model.deleteOne(filter)`, `Model.deleteMany(filter)`
- `Model.count(filter)`
- `Model.aggregate()` — stub returning `[]` (needs JS-level overrides per model)
- `new Model(data)` → `FirestoreDocument` with field access, `save()`, `remove()`
- `doc.save()` — runs Mongoose `pre('save', fn)` hooks before writing
- `doc.isModified(field)`, `doc.markModified(field)`, `doc.set()`, `doc.get()`
- `schema.methods` — attached to loaded document instances
- Collection name: `modelName.toLowerCase() + 's'` (e.g. User → users)

**Stubbed / not yet implemented**:
- `aggregate()` — returns `[]`; models using it need per-method JS overrides
- `populate()` — no-op; callers do N+1 explicitly (acceptable for this use case)

## Smoke test results (Firestore emulator)

All tested against `FIRESTORE_EMULATOR_HOST=localhost:8080`:
- save + findById round-trip ✓
- findOne with equality filter ✓
- find + sort + limit ✓
- count ✓
- findByIdAndUpdate with $set ✓
- findByIdAndUpdate with $inc ✓
- deleteOne ✓
- $or query ✓
- pre-save hooks (field mutation persisted) ✓
- schema.methods attached to loaded instances ✓
- Full app boot with Firestore backend ✓
- GET / → 200, GET /login → 200 ✓
- GET /api/trinkets → 401 (auth check working) ✓

## Current config (local.yaml additions)

```yaml
db:
  backend: firestore
  firestore:
    projectId: demo-trinket   # matches GOOGLE_CLOUD_PROJECT for emulator
  mongo:
    host: localhost    # Docker test-mongo on localhost:27017 (for sessions)
    port: 27017
    database: trinket
  redis:
    enabled: false
```

## What still needs MongoDB

The session store (`lib/util/catbox-mongoose.js`) uses Mongoose/MongoDB directly.
It is separate from the model-layer backend and is **not** controlled by
`config.db.backend`. The app currently requires MongoDB for sessions even when
the Firestore backend is active.

## Next slice: Firestore session store

Replace `lib/util/catbox-mongoose.js` with a Firestore-backed equivalent.
It must implement the `@hapi/catbox` engine interface:
- `start()` — async, connect/initialize
- `stop()` — cleanup
- `isReady()` → boolean
- `validateSegmentName(name)` → null (valid) or Error
- `get(key)` → `{ item, stored, ttl }` or `null`
- `set(key, value, ttl)` → void
- `drop(key)` → void
- `key` shape: `{ segment: string, id: string }`

Collection should be `sessions`. Each document: `{ _id, value, stored, ttl }`.
TTL enforcement via JS (check `Date.now() - stored > ttl` on get) — Firestore
doesn't support server-side TTL indexes like MongoDB does.

After the session store is done, the `test-mongo` Docker container (and
catbox-mongoose) can be removed entirely. That completes the full MongoDB
elimination.

## After the session store: Redis slug stores

`lib/util/store/userStore.js`, `courseStore.js`, `trinketStore.js` are
**functional** (slug → ID lookup), not just caches. They currently use
in-memory fallback (Redis disabled). For production on Cloud Run they need
Firestore equivalents — a simple collection per store with `slug` as the
document ID.

## Setup on a new machine

```bash
# Prerequisites: Node 16 (via nvm), Firebase CLI for the emulator
nvm use 16
npm install --legacy-peer-deps

# Install Firebase CLI and Firestore emulator (requires Java 11+)
npm install -g firebase-tools
firebase setup:emulators:firestore

# Start the emulator (run in a separate terminal, any Node version)
firebase emulators:start --only firestore --project demo-trinket

# In your main terminal (Node 16):
export FIRESTORE_EMULATOR_HOST=localhost:8080
export GOOGLE_CLOUD_PROJECT=demo-trinket

# For sessions, MongoDB is still needed (temporarily):
docker run -d --name test-mongo -p 27017:27017 mongo:5

# Start the app
node app.js
```

---

## Resume prompt

Paste this at the start of a new Claude Code session in this repo:

```
We're implementing a Firestore Native adapter for trinket-oss so it can run
on Google Cloud Run without MongoDB or Redis. Read IMPLEMENTATION.md first —
it has the full architecture, what's been done, and the exact next step.

The short version: Slices 1 and 2 are committed and tested. The model layer
routes through lib/db/firestore-backend.js (Option A — MongoDB query syntax
translated internally). The app boots and serves pages with Firestore active.

The only remaining MongoDB dependency is the session store
(lib/util/catbox-mongoose.js). The next slice is to replace it with a
catbox-compatible Firestore engine. Spec is in IMPLEMENTATION.md under
"Next slice: Firestore session store".

After sessions: implement Firestore-backed slug stores to replace the
in-memory Redis fallback in lib/util/store/.

Use the Firestore emulator (FIRESTORE_EMULATOR_HOST=localhost:8080) for all
local testing. Node 16 is required (bcrypt native addon).
```
