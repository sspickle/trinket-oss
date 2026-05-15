# Trinket Firestore Adapter — Implementation Log

## Architecture decision

**Option A**: Firestore backend translates MongoDB-style query syntax internally.
Existing class methods in all model files are unchanged. The backend factory
selects the adapter at boot time via `config.db.backend`.

## Slices completed

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

### Slice 3 — Firestore session store (current branch)
- `lib/util/catbox-firestore.js` — catbox engine backed by Firestore `sessions`
  collection. Values are JSON-serialized; TTL is enforced client-side on `get()`.
- `config/db.js` — skips MongoDB `connect()` when `db.backend !== 'mongoose'`.
- `app.js` — reads `config.db.backend` at startup and selects `catbox-firestore`
  or `catbox-mongoose` accordingly (backwards-compatible).

### Slice 4 — Firestore slug stores (current branch)
- `lib/util/store/firestore-client.js` — Firestore-backed list client
  implementing `lIndex`, `lPush`, `lRem`, `lRange`, `rPush`, `exists`
  (all backed by `store_lists` collection, transactional read-modify-write).
- `lib/util/store.js` — added `_getStoreClient` that routes `trinkets()`,
  `courses()`, and `users()` sub-stores through `firestore-client` when
  `db.backend === 'firestore'`. Base `get/set/del/expire` (temp tokens) keep
  using in-memory fallback (unchanged).
- `test/smoke-firestore-sessions.js` — 16-case smoke test covering both modules.

### Slice 5 — Cloud Run deployment prep (current branch)
- `config/cloudrun.yaml` — replaced MongoDB URI placeholder with
  `db.backend: firestore` and `db.redis.enabled: false`. `db.firestore.projectId`
  is intentionally absent; the Firestore SDK reads `GOOGLE_CLOUD_PROJECT`
  automatically on Cloud Run. `app.url.hostname` is injected at runtime via
  `NODE_CONFIG` by `deploy.sh`.
- `deploy.sh` — end-to-end deploy script (see "Deploying to Cloud Run" below).
- `.dockerignore` — added `node_modules`, `config/local.yaml` (and variants),
  `.env`, `*.log` to prevent secrets and build artifacts from entering the image.

## Smoke test results (Firestore emulator, Slices 1–2)

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

## Smoke test results (Slices 3–4)

`test/smoke-firestore-sessions.js` — 16 cases, all green:
- catbox-firestore: start/stop, get/set round-trip, TTL expiry, drop ✓
- firestore-client: lIndex, lPush, lRange, rPush, lRem, exists, negative index ✓

## MongoDB elimination status

**Complete** when `db.backend: firestore` is set in config. With that config:
- `config/db.js` skips the Mongoose/MongoDB connection.
- Sessions use `catbox-firestore` (Firestore `sessions` collection).
- Slug stores (userStore, courseStore, trinketStore) use `firestore-client`.
- Model layer uses `firestore-backend.js` (unchanged from Slice 2).
- The `test-mongo` Docker container is no longer needed.

The `catbox-mongoose.js` file is retained for backwards compatibility when
`db.backend: mongoose` (the default).

## What still runs in-memory (not yet persisted to Firestore)

The base `Store.get/set/del/expire` methods in `lib/util/store.js` are used for
temporary tokens: password reset, email verification, account activation. They
fall through to `InMemoryClient` when Redis is disabled. On Cloud Run (scales to
zero), these tokens will be lost on restart. A future slice can back them with
Firestore as well, but it is low priority (users can simply re-request a reset).

## Local development setup

### 1. config/local.yaml additions (Firestore mode)

```yaml
db:
  backend: firestore
  firestore:
    projectId: demo-trinket   # must match GOOGLE_CLOUD_PROJECT below
  redis:
    enabled: false
```

No MongoDB connection string needed. The `mongo:` block from the default config
is ignored when `backend: firestore`.

### 2. Start the emulator and app

```bash
# Prerequisites: Node 16 (via nvm), Firebase CLI, Java 11+
nvm use 16
npm install --legacy-peer-deps
npm install -g firebase-tools
firebase setup:emulators:firestore   # one-time download

# Terminal 1 — emulator (any Node version)
firebase emulators:start --only firestore --project demo-trinket

# Terminal 2 — app (Node 16)
export FIRESTORE_EMULATOR_HOST=localhost:8080
export GOOGLE_CLOUD_PROJECT=demo-trinket
node app.js
```

### 3. Smoke tests

```bash
# Unit/integration smoke test (sessions + slug stores):
FIRESTORE_EMULATOR_HOST=localhost:8080 GOOGLE_CLOUD_PROJECT=demo-trinket \
NODE_ENV=development node test/smoke-firestore-sessions.js

# HTTP smoke test (app must be running):
curl http://localhost:3000/          # → 200
curl http://localhost:3000/login     # → 200
curl http://localhost:3000/api/trinkets  # → 401
```

## Deploying to Cloud Run

### Prerequisites

- `gcloud` CLI installed and authenticated (`gcloud auth login`)
- A GCP project with billing enabled

### Run the script

```bash
export GCP_PROJECT=your-gcp-project-id
./deploy.sh
```

The script handles everything in order:
1. Enables required APIs (Cloud Run, Cloud Build, Secret Manager, Firestore)
2. Creates the Firestore Native database if it doesn't exist
3. Creates the `trinket-session-password` secret in Secret Manager (prompts
   for the password on first run)
4. Grants IAM roles to the Cloud Run default compute SA:
   `secretmanager.secretAccessor` and `datastore.user`
5. Builds the container image via Cloud Build (no local Docker required)
6. Deploys to Cloud Run with `NODE_ENV=production`, `NODE_APP_INSTANCE=cloudrun`,
   `GOOGLE_CLOUD_PROJECT`, and `SESSION_PASSWORD` from Secret Manager
7. Patches `NODE_CONFIG` with the service hostname after the first deploy

### Optional overrides

```bash
export GCP_REGION=us-east1          # default: us-central1
export SERVICE_NAME=trinket-staging # default: trinket
export MEMORY=1Gi                   # default: 512Mi
export MAX_INSTANCES=20             # default: 10
```

### Environment variables set on the Cloud Run service

| Variable | Source | Purpose |
|---|---|---|
| `NODE_ENV` | deploy.sh | `production` — disables dev logging, enables prod Hapi config |
| `NODE_APP_INSTANCE` | deploy.sh | `cloudrun` — loads `config/cloudrun.yaml` via node-config |
| `GOOGLE_CLOUD_PROJECT` | deploy.sh | GCP project ID for Firestore SDK auto-detection |
| `NODE_CONFIG` | deploy.sh | JSON override injecting `app.url.hostname` |
| `SESSION_PASSWORD` | Secret Manager | Cookie signing key (32+ chars) |
| `PORT` | Cloud Run | Set automatically; app.js reads it |

---

## Resume prompt

Paste this at the start of a new Claude Code session in this repo:

```
We're deploying trinket-oss to Google Cloud Run backed by Firestore Native
(no MongoDB, no Redis). Read IMPLEMENTATION.md for full context.

Slices 1–5 are complete and uncommitted on branch cloud-run-deploy:
- Slice 1–2: Firestore model-layer adapter (lib/db/firestore-backend.js)
- Slice 3: Firestore session store (lib/util/catbox-firestore.js);
           MongoDB connection skipped in config/db.js when backend=firestore
- Slice 4: Firestore slug stores (lib/util/store/firestore-client.js)
- Slice 5: Cloud Run deploy script (deploy.sh) and config (config/cloudrun.yaml)

The remaining in-memory state is Store.get/set/del/expire (password-reset
tokens, email verification). Low priority — users can re-request.

Local testing: set db.backend: firestore in config/local.yaml, start the
Firestore emulator, then node app.js. See "Local development setup" in
IMPLEMENTATION.md. Node 16 required (bcrypt native addon).

Deploy: export GCP_PROJECT=your-project && ./deploy.sh
```
