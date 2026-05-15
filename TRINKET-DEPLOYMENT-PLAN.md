# Trinket-OSS: GCR Deployment & Firestore Adapter Plan

**Date:** 2026-04-06 (revised)
**Codebase:** trinket-oss (Hapi.js + Mongoose + Redis + S3)

---

## Table of Contents

1. [Context & Goals](#1-context--goals)
2. [Codebase Overview](#2-codebase-overview)
3. [Project 1: Test Deployment on GCR with Atlas-MongoDB](#3-project-1-test-deployment-on-gcr-with-atlas-mongodb)
4. [Project 2: Firestore Native Adapter](#4-project-2-firestore-native-adapter)
5. [MongoDB Feature Audit](#5-mongodb-feature-audit)
6. [Firestore Native vs Datastore vs MongoDB](#6-firestore-native-vs-datastore-vs-mongodb)
7. [Adapter Architecture & Phased Plan](#7-adapter-architecture--phased-plan)

---

## 1. Context & Goals

### Use Case

This deployment serves **GlowScript** (VPython in the browser). All code execution
happens client-side via either the RapydScript runner (`glowThings/rsWVPRunner/`) or
the WASM/Pyodide runner (`glowThings/wmWVPRunner/`), embedded in the Trinket UI.

**Server-side code execution (Python/Java/R/Pygame Docker containers in `serverside/`)
is not needed and will not be deployed.**

### Usage Pattern

- Users are primarily **students** using the system for a semester
- Activity is **bursty**: heavy during a term, then dormant -- possibly forever
- Data is **long-lived** but reads/writes drop to near-zero after the course ends
- Many users, low sustained throughput

### Why Firestore Over Atlas

| | Atlas MongoDB | Firestore (Native) |
|---|---|---|
| **Pricing model** | Storage volume (pay even when idle) | Per read/write (idle data is nearly free) |
| **Free tier** | 512 MB shared cluster (M0) | 1 GB storage, 50K reads/day, 20K writes/day |
| **Dedicated pricing** | ~$57/mo minimum (M10) | $0.06/100K reads, $0.18/100K writes, $0.18/GB/mo storage |
| **Idle cost for 10 GB of dormant student data** | ~$57+/mo (must keep cluster running) | ~$1.80/mo (storage only, zero read/write cost) |
| **Scaling** | Manual tier upgrades | Automatic |
| **GCP integration** | Third-party (Atlas) | Native (IAM, VPC, monitoring) |

**Bottom line:** Atlas penalizes the "lots of students who use it once" pattern.
Firestore's per-operation pricing is ideal for bursty educational use.

### Strategy

1. **Phase 1 (now):** Deploy a test instance on GCR + Atlas to learn the deployment
   pipeline and validate the app works on Cloud Run. This is throwaway/testing only.
2. **Phase 2 (main effort):** Build a Firestore Native adapter so the production
   deployment avoids ongoing Atlas costs.

---

## 2. Codebase Overview

### Architecture

| Layer | Technology | Notes |
|-------|-----------|-------|
| Web framework | Hapi 20 | Routes, auth, sessions, views (Nunjucks) |
| ORM | Mongoose 6 | 15 models, custom model factory, plugins, aggregation |
| Cache/Queues | Redis + Bull | Falls back to in-memory when disabled (Cloud Run config) |
| File storage | AWS S3 | User assets, snapshots, avatars, exports (7 buckets) |
| Code execution | Docker containers | **NOT NEEDED** -- GlowScript runs in-browser |
| Frontend | Angular 1.x + Ace editor | Served from `public/` |

### Data Models (15 total)

**Core:** User, Course, Lesson, Material, Trinket ("Snippet"), File, Folder
**Supporting:** Interaction, Draft, CourseInvitation, Export, FeaturedCourses
**Analytics:** ClientMetric, ErrorEvent, Asset (embedded schema)

### Key Relationships

```
User -[owns]-> Course -[has]-> Lesson -[has]-> Material -[links]-> Trinket
User -[owns]-> Trinket (standalone or via Folder)
User -[owns]-> File (assets embedded in Trinket)
Trinket -[forks/remixes]-> Trinket (_parent, _origin_id)
```

### How MongoDB Is Used Today

The app uses a custom model factory (`lib/models/model.js`) wrapping Mongoose with:
- Schema definitions with 7 plugins (timestamps, ownable, roles, slug, paginate, isChanged, orderedList)
- `classMethods` and `objectMethods` bound to model instances
- Automatic `findById`, `findByIds`, `findByIdAndUpdate` with alternate ID support
- Controllers call the public model API (e.g., `Trinket.findByOwner()`), not raw Mongoose

This factory is already a layer of abstraction -- a good foundation for the adapter.

---

## 3. Project 1: Test Deployment on GCR with Atlas-MongoDB

**Purpose:** Learn GCR deployment, validate the app runs on Cloud Run, test with real data.
**Not for production** -- Atlas costs make it impractical long-term.

### What Already Exists

1. **`deploy-cloudrun.sh`** -- Builds via Cloud Build, deploys to Cloud Run
2. **`config/cloudrun.yaml`** -- Disables Redis, reads `MONGODB_URI` from env
3. **`config/db.js`** -- Supports `MONGODB_URI` env var and `mongodb+srv://` strings
4. **Redis fallback** -- In-memory client in `lib/util/store.js` when Redis disabled
5. **Sessions in MongoDB** -- Custom `catbox-mongoose` engine, no Redis dependency

### Steps

1. **Atlas:** Create free M0 cluster, database user, whitelist `0.0.0.0/0`
2. **Environment variables:**
   ```bash
   export GCP_PROJECT=your-project
   export MONGODB_URI='mongodb+srv://...'
   export SESSION_PASSWORD='<32+ char password>'
   ```
3. **Run:** `./deploy-cloudrun.sh`
4. **Post-deploy:** Update `config/cloudrun.yaml` with actual Cloud Run URL

### What To Skip For Test

- **S3/file uploads:** Not needed for basic testing. Trinkets work without uploaded assets.
- **SMTP/email:** Disable or use a free SMTP service. Password resets and invitations won't work without it.
- **Serverside execution:** Not needed (GlowScript is client-side).

### What To Validate

- User registration and login
- Creating/editing/saving trinkets (GlowScript type)
- Course creation, lesson/material management
- Folder organization
- Search functionality
- Session persistence across requests

**Effort: 1-2 days.**

---

## 4. Project 2: Firestore Native Adapter

### Why Firestore Native Mode (Not Datastore Mode)

Firestore has two modes, chosen **once per GCP project** (irreversible). Native mode
is strictly better for this project:

| Feature | Datastore Mode | Firestore Native | MongoDB | Impact |
|---------|---------------|-----------------|---------|--------|
| **OR queries** | No | **Yes** | Yes | **Fixes 8 call sites** |
| `!=` operator | No | **Yes** | Yes | Fixes 5 `$ne` sites |
| `in` (up to 30) | Limited | **Yes** | Yes | Covers `$in` usage |
| `not-in` (up to 10) | No | **Yes** | Yes | Minor help |
| `array-contains` | No | **Yes** | N/A | Helps with flat array queries |
| Count aggregation | No | **Yes** | Yes | Fixes `.count()` usage |
| Sum/Average | No | **Yes** | Yes | Could help with metrics |
| Subcollections | No | **Yes** | N/A | Better for Course->Lesson->Material |
| Transactions | Basic | **Better** | Yes | Safer `$inc`/`$push` replacement |
| Real-time listeners | No | **Yes** | No | Bonus: live collaboration potential |

**Firestore Native eliminates roughly half the compatibility issues** compared to
Datastore mode. The OR query support alone is the single biggest win -- it was
the most pervasive incompatibility (8 locations including login and search).

### What Firestore Native Still Cannot Do

| MongoDB Feature | Usage | Firestore Alternative |
|----------------|-------|----------------------|
| **Regex search** | 1 site (`searchForOwner`) | Client-side filtering (owner-scoped, <1000 docs) or prefix match |
| **`$elemMatch`** | 7 sites (query/update nested array objects) | Denormalize to subcollections or read-modify-write |
| **Aggregation pipelines** | 5 pipelines ($group, $project, computed fields) | Application-level JS (all are classroom-scale datasets) |
| **Positional `$` update** | 5 sites (update array element by match) | Read-modify-write in transaction |
| **`$push`/`$pull`/`$addToSet`** | 10+ sites (atomic array ops) | Read-modify-write in transaction (`arrayUnion`/`arrayRemove` for simple values) |
| **`$inc`** | 3 sites (atomic counter increment) | Transaction or `FieldValue.increment()` (Firestore **does** have this!) |
| **`.populate()` joins** | 2 sites (Course->Lessons->Materials) | N+1 queries or denormalize (subcollections help) |
| **Compound unique index** | 3 sites | Application-level enforcement in transaction |
| **Schema hooks** | 8 hooks (pre/post save/remove) | Application middleware layer |

**Correction from earlier analysis:** Firestore Native actually supports `FieldValue.increment()`,
which means the `$inc` pattern (3 sites: view counters, fork counters, file metrics) is natively
supported. That's another gap closed.

### Search Strategy

Current search (`trinket.js:264-290`) is a case-insensitive regex over `name` and
`description`, scoped to one owner's non-deleted trinkets, limited to 20 results.

**Recommended approach: Client-side filtering.**

Rationale:
- Search is always scoped to a single owner's trinkets
- A typical user has 10s to low 100s of trinkets
- Fetch all owner's trinkets (just name + description fields), filter in JS
- No external search service needed
- Could add a lowercase `nameLower` field for case-insensitive prefix matching as an optimization

If search needs grow, Firestore has a [vector search extension](https://firebase.google.com/docs/firestore/vector-search)
and integrations with Algolia/Typesense, but this is likely overkill.

---

## 5. MongoDB Feature Audit

### Complete Feature Usage with Firestore Native Compatibility

| Category | MongoDB Feature | Count | Firestore Native? | Workaround Needed? |
|----------|----------------|-------|-------------------|-------------------|
| Basic CRUD | find, findOne, findById, save, delete | 50+ | **Yes** | No |
| Equality filters | `{ field: value }` | 50+ | **Yes** | No |
| Range queries | `$gt`, `$lt`, `$gte`, `$lte` | 5 | **Yes** | No |
| In-list | `$in` | 4 | **Yes** (max 30) | No |
| Not-equal | `$ne` | 5 | **Yes** | No |
| Exists | `$exists` | 3 | **Yes** (`!=` null) | No |
| Sort | `.sort()` | 10 | **Yes** | Composite index for multi-field |
| Count | `.count()` | 1 | **Yes** | No |
| **OR queries** | `$or` | **8** | **Yes** | No |
| **Atomic increment** | `$inc` | **3** | **Yes** (`increment()`) | No |
| Pagination | `.skip()`, `.limit()` | 8 | **Partial** | Cursors yes, offset-skip needs rework |
| **Regex search** | `RegExp()` | 1 | **No** | Client-side filter |
| **Array subdoc query** | `$elemMatch` | 7 | **No** | Denormalize to subcollections |
| **Aggregation** | `.aggregate()` | 5 | **No** | JS application code |
| **Array mutation** | `$push`, `$pull`, `$addToSet` | 10+ | **Partial** | `arrayUnion`/`arrayRemove` for flat values; transaction for objects |
| **Positional update** | `$set` with `$` | 5 | **No** | Read-modify-write in transaction |
| **Upsert** | `findOneAndUpdate` + upsert | 2 | **Partial** | Transaction with `set(merge: true)` |
| **Populate/Join** | `.populate()` | 2 | **No** | Subcollections or N+1 queries |
| **Compound unique** | `unique` compound index | 3 | **No** | Application-level in transaction |
| **Schema hooks** | pre/post save/remove | 8 | **No** | Application middleware |

### Summary

- **Natively compatible (no workaround):** ~75% of query sites
- **Needs minor workaround (transaction, client-side):** ~15%
- **Needs structural change (denormalize, rewrite):** ~10%

The structural changes are concentrated in:
1. **Aggregation pipelines** (5 pipelines, all classroom-scale)
2. **Embedded array subdocuments** (Course.users, Trinket.comments, Folder.trinkets)

---

## 6. Firestore Native vs Datastore vs MongoDB

### Compatibility Scorecard

| Problem Area | Sites | Datastore | Firestore Native | Delta |
|-------------|-------|-----------|-----------------|-------|
| `$or` queries | 8 | Manual multi-query | **Native support** | 8 sites fixed |
| `$ne` filters | 5 | Not supported | **Native support** | 5 sites fixed |
| `$exists` check | 3 | Not supported | **`!= null`** | 3 sites fixed |
| `$inc` counters | 3 | Read-modify-write | **`increment()`** | 3 sites fixed |
| Count queries | 1 | Not supported | **`count()`** | 1 site fixed |
| `$in` queries | 4 | Limited | **Up to 30** | 4 sites fixed |
| Regex search | 1 | Not supported | Not supported | Client-side for both |
| `$elemMatch` | 7 | Not supported | Not supported | Denormalize for both |
| Aggregation | 5 | Not supported | Not supported | JS rewrite for both |
| `$push`/`$pull` | 10+ | Read-modify-write | **Partial** (`arrayUnion`) | ~half improved |

**Firestore Native eliminates 24+ compatibility issues that Datastore would require
workarounds for.** The remaining hard problems are the same in both modes.

### Data Model: Firestore Subcollection Mapping

Firestore's subcollection model is a natural fit for the Course hierarchy:

```
courses/{courseId}
  ├── enrollments/{enrollmentId}     (replaces embedded users[])
  │     { userId, username, roles[], deleted }
  ├── invitations/{invitationId}     (replaces separate CourseInvitation collection)
  │     { email, token, status, sentOn }
  └── (lessons are separate top-level for flexibility)

lessons/{lessonId}
  └── materials/{materialId}         (or keep as top-level with lessonId field)

trinkets/{trinketId}
  ├── comments/{commentId}           (replaces embedded comments[])
  │     { author, commentText, commented }
  └── assets stored as array of simple objects (no $elemMatch needed if denormalized)

folders/{folderId}
  └── memberships/{membershipId}     (replaces embedded trinkets[])
        { trinketId, name, lang, shortCode }

users/{userId}
  └── roles stored as subcollection or map field
```

This structure eliminates the need for `$elemMatch` entirely -- each embedded array
becomes a queryable subcollection.

---

## 7. Adapter Architecture & Phased Plan

### Architecture: Thin Adapter on Existing Model Factory

The existing `lib/models/model.js` factory already provides a public API that controllers
call. The adapter builds on this:

```
Controllers (unchanged)
    |
    v
Model Public API (findById, findByOwner, searchForOwner, ...)
    |
    v
model.js factory (modified to delegate to backend)
    |
    +--> mongoose-backend.js  (wraps current Mongoose code, 1:1)
    |
    +--> firestore-backend.js (implements same interface with @google-cloud/firestore)
    |
    selected by: config.db.backend = 'mongoose' | 'firestore'
```

Plugins (timestamps, ownable, roles, slug, etc.) get equivalent Firestore implementations
that run as pre/post-save middleware in the adapter layer.

### Phase 1: Foundation (Week 1-2)

**Goal:** Basic CRUD operations working on Firestore.

- [ ] Create `lib/db/firestore-backend.js` implementing core operations:
  - `findById`, `findOne`, `find` (with equality/range/in/or filters)
  - `save`, `delete`, `deleteMany`
  - `findByIdAndUpdate` (read-modify-write in transaction)
- [ ] Create `lib/db/backend-factory.js` to select backend from config
- [ ] Modify `lib/models/model.js` to delegate through backend factory
- [ ] Implement timestamp and ownable plugin equivalents
- [ ] Get User model working: registration, login, findByLogin (`$or` -- native in Firestore)
- [ ] Get basic Trinket CRUD working
- [ ] Validate with existing test suite

### Phase 2: Relationships & Denormalization (Week 2-3)

**Goal:** Course/Lesson/Material hierarchy and folder management.

- [ ] Design subcollection structure for Course enrollments
- [ ] Implement Course model with enrollment subcollection (replaces `$elemMatch` on users[])
- [ ] Implement Folder with membership subcollection (replaces embedded trinkets[])
- [ ] Implement Trinket comments as subcollection
- [ ] Implement roles plugin for Firestore (map field or subcollection)
- [ ] Replace `.populate()` calls with explicit multi-get
- [ ] Implement slug plugin with uniqueness check in transaction

### Phase 3: Aggregation & Search (Week 3-4)

**Goal:** Course dashboards, trinket listing, and search.

- [ ] Reimplement `trinket.list()` aggregation as: Firestore query + JS compute + JS sort/paginate
- [ ] Reimplement `courseDashboard()` as: fetch trinkets by courseId + JS grouping
- [ ] Reimplement `findSubmissionsByMaterial()` as: fetch + JS grouping
- [ ] Reimplement `findSubmissionsByUserAndCourse()` as: fetch + JS grouping
- [ ] Implement `searchForOwner()` as: fetch owner's trinkets + JS regex filter
- [ ] Implement pagination plugin equivalent using Firestore cursors

### Phase 4: Polish & Sessions (Week 4-5)

**Goal:** Sessions, metrics, remaining models, testing.

- [ ] Replace `catbox-mongoose` session store with Firestore-backed session store
- [ ] Implement `$inc` equivalent using `FieldValue.increment()` for metrics
- [ ] Implement remaining models: Interaction, Draft, Export, ClientMetric, ErrorEvent, FeaturedCourses
- [ ] Implement CourseInvitation (compound uniqueness via transaction)
- [ ] Implement upsert patterns for Draft
- [ ] End-to-end testing of all user flows
- [ ] Performance testing with realistic data volumes

### Phase 5: Cleanup & GlowScript Simplification (Week 5-6)

**Goal:** Remove unused features, optimize for GlowScript-only use.

- [ ] Remove serverside execution config and routes (Python/Java/R/Pygame)
- [ ] Simplify language config to GlowScript only
- [ ] Remove unused models if any (ErrorEvent may not apply to client-side execution)
- [ ] Replace S3 with GCS (or keep S3 if cost-neutral)
- [ ] Production deployment on Cloud Run + Firestore
- [ ] Document deployment and configuration

### Estimated Timeline

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| Phase 1: Foundation | 2 weeks | User + Trinket CRUD on Firestore |
| Phase 2: Relationships | 1-2 weeks | Full data model on Firestore |
| Phase 3: Aggregation | 1 week | Dashboards and search working |
| Phase 4: Polish | 1-2 weeks | Sessions, metrics, all models |
| Phase 5: Cleanup | 1 week | Production-ready, GlowScript-focused |
| **Total** | **5-8 weeks** | |

### Risk Mitigation

- **Mongoose backend preserved:** The adapter keeps the Mongoose path working. If Firestore
  migration stalls, the Atlas test instance still works.
- **Phase 1 is the proof of concept:** If User + Trinket CRUD works on Firestore, the rest
  is mechanical. If it's harder than expected, reassess before investing in phases 2-5.
- **GlowScript simplification reduces scope:** Removing serverside execution, multi-language
  support, and unused features shrinks the surface area significantly.
