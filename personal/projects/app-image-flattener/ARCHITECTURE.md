# Flatten — Architecture & Build Sequence

**Companion to [SPEC.md](./SPEC.md). Reorients the system around the primary use case: flattening RAW images driven by ratings that live in *other* catalogs (Lightroom Classic first, then XMP-writing apps like Capture One, Bridge, darktable, Photo Mechanic).**

Draft v0.1 — 2026-08-18

---

## 1. The architectural center of gravity

The primary use case dictates the architecture: this app is, at its core, a **metadata-join engine**. Its hardest and most valuable job is answering, correctly and fast:

> *"For this RAW file on disk, what does the photographer's catalog say about it?"*

Everything else (rendering, encoding, UI) is well-trodden ground with good OS support. The catalog join is where the product wins or loses, so it gets:

- **first position in the build sequence** (Phase 1, before any pixel is ever encoded),
- **its own isolated module** (`CatalogKit`) with the largest test fixture investment,
- **a normalized internal model** (`RatingRecord`) that every catalog format is translated into, so the rest of the app never knows or cares where a rating came from.

The three hard problems, in order of risk:

| # | Problem | Why it's hard |
|---|---|---|
| 1 | **Path reconciliation** — matching a catalog's notion of a file to the file actually on disk | LR stores volume + folder + filename with its own volume identity model; drives get renamed, folders reorganized, catalogs reference offline volumes; case-insensitivity; RAW+JPEG pairs; sidecars |
| 2 | **Rating truth & precedence** — one image may have a rating in the LR catalog, a *different* one in its XMP sidecar, and a third embedded in the file | LR only writes XMP on demand; sidecars go stale; users run multiple tools |
| 3 | **Safe destructive I/O** — originals must never be lost, even on crash/power-loss mid-batch | Ordering guarantees, verification, journaling |

The architecture below is shaped by these three.

---

## 2. System overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                            Flatten.app (SwiftUI)                    │
│   Sources UI · Rule Builder · Grid/Loupe · Plan Sheet · Journal UI  │
└───────────────┬─────────────────────────────────────────────────────┘
                │  observes (AsyncSequence / @Observable stores)
┌───────────────▼─────────────────────────────────────────────────────┐
│                         FlattenCore  (SPM package, no AppKit/UI)    │
│                                                                     │
│  ┌───────────┐   ┌────────────┐   ┌──────────┐   ┌──────────────┐   │
│  │ ScanKit   │   │ CatalogKit │   │ RulesKit │   │ PipelineKit  │   │
│  │ disk      │   │ lrcat/XMP/ │   │ predicate│   │ decode→encode│   │
│  │ discovery │   │ embedded   │   │ engine   │   │ →verify→     │   │
│  │           │   │ readers    │   │          │   │ finalize     │   │
│  └─────┬─────┘   └─────┬──────┘   └────┬─────┘   └──────┬───────┘   │
│        │               │               │                │           │
│  ┌─────▼───────────────▼───────────────▼─────┐   ┌──────▼───────┐   │
│  │              IndexStore (SQLite)          │   │  JournalKit  │   │
│  │  images · rating_records · sources ·      │   │  operation   │   │
│  │  overrides · size_model · thumbs cache    │   │  log / undo  │   │
│  └───────────────────────────────────────────┘   └──────────────┘   │
│                                                                     │
│  RenderKit (decode/encode primitives, used by PipelineKit & thumbs) │
└─────────────────────────────────────────────────────────────────────┘
                │ also driven by
        ┌───────▼────────┐
        │  flatten-cli   │  headless harness: scan, join, dry-run,
        │  (dev tool)    │  flatten — the engine ships before the UI
        └────────────────┘
```

**Rule zero:** `FlattenCore` is a pure Swift package with zero UI dependencies, driven equally by the app and by `flatten-cli`. This keeps the risky 60% of the product testable in CI against fixture catalogs from day one, and forces clean seams.

---

## 3. Data model (IndexStore)

SQLite via GRDB. One database per "workspace" (the user's set of sources), stored in Application Support. Schema essentials:

```sql
-- A place ratings/files come from: a folder tree, an .lrcat, a C1 catalog
CREATE TABLE sources (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,              -- 'folder' | 'lrcat' | 'c1' | 'photos'
  bookmark BLOB NOT NULL,          -- security-scoped bookmark
  display_name TEXT,
  last_scanned_at INTEGER,
  catalog_schema_version TEXT      -- for lrcat/c1 degradation decisions
);

-- One logical image (RAW+JPEG pair collapses to one row, pair recorded)
CREATE TABLE images (
  id INTEGER PRIMARY KEY,
  volume_uuid TEXT NOT NULL,       -- APFS/HFS volume UUID
  rel_path TEXT NOT NULL,          -- path relative to volume root
  filename TEXT NOT NULL,
  ext TEXT NOT NULL,
  file_size INTEGER NOT NULL,
  mtime INTEGER NOT NULL,
  capture_time INTEGER,            -- from EXIF fast-path
  camera_model TEXT, camera_serial TEXT, lens TEXT,
  content_key TEXT,                -- hash(embedded preview)+capture_time: dupe & relink identity
  jpeg_sibling_path TEXT,          -- RAW+JPEG pair
  xmp_sidecar_path TEXT,
  state TEXT NOT NULL DEFAULT 'present',  -- present | offline | flattened | missing
  UNIQUE(volume_uuid, rel_path)
);

-- THE JOIN TABLE: every opinion any catalog holds about an image.
-- Multiple rows per image are expected and are the point.
CREATE TABLE rating_records (
  id INTEGER PRIMARY KEY,
  image_id INTEGER NOT NULL REFERENCES images(id),
  source_id INTEGER NOT NULL REFERENCES sources(id),
  origin TEXT NOT NULL,            -- 'lrcat' | 'xmp_sidecar' | 'embedded_xmp' | 'c1'
  rating INTEGER,                  -- 0-5, NULL = unrated
  flag TEXT,                       -- 'pick' | 'reject' | NULL
  color_label TEXT,                -- normalized: red/yellow/green/blue/purple/custom:<name>
  keywords TEXT,                   -- JSON array
  collections TEXT,                -- JSON array of collection paths (lrcat/c1 only)
  has_develop_edits INTEGER,       -- lrcat only
  recorded_at INTEGER,             -- catalog's own timestamp where available
  match_confidence TEXT NOT NULL,  -- 'exact' | 'relinked' | 'content' (how the join was made)
  UNIQUE(image_id, source_id, origin)
);

-- Per-image user pins that survive rule changes
CREATE TABLE overrides (
  image_id INTEGER PRIMARY KEY REFERENCES images(id),
  action TEXT NOT NULL             -- 'protect' | 'flatten'
);
```

### 3.1 EffectiveRating — the precedence resolver

The rest of the app never reads `rating_records` directly. `CatalogKit` exposes one resolved view:

```swift
struct EffectiveRating: Sendable {
  var rating: Int?          // 0-5
  var flag: Flag?           // pick / reject
  var colorLabel: Label?
  var keywords: [String]
  var collections: [String]
  var provenance: [Claim]   // every underlying record, for the inspector UI
  var conflicts: Bool       // true when sources disagree on rating/flag
}
```

Default precedence (user-configurable per workspace, surfaced in Settings as an ordered list):

```
lrcat (open catalog snapshot)  >  xmp_sidecar  >  c1  >  embedded_xmp
```

Rationale: LR's database is what the photographer actually curates in; sidecars are exports that go stale the moment they're written. **Conflicts are never silently resolved for destructive purposes** — a `conflicts=true` image gets a badge in the grid, is countable via a "Conflicting ratings" filter, and (by default setting) is auto-protected from flattening until the user looks at it. This is the trust story of §1 problem 2, made concrete.

### 3.2 Path reconciliation (§1 problem 1)

Join strategy in `CatalogKit.Reconciler`, attempted in order, recording `match_confidence`:

1. **Exact**: catalog volume identity + relative path + filename matches a scanned file. LR's `AgLibraryRootFolder.absolutePath` is matched against mounted volumes; volume UUID preferred over volume name.
2. **Relinked**: filename + capture time + file size match under a different root (drive renamed / folders moved). Requires uniqueness — ambiguous candidates are left unmatched, never guessed.
3. **Content**: `content_key` match (embedded-preview hash + capture time) for renamed files. Same uniqueness requirement.

Unmatched catalog entries and unmatched disk files are both first-class query results ("In catalog but not found on disk: 214", "On disk but unknown to any catalog: 1,832") — the second group is itself a prime flattening candidate and gets a built-in preset.

---

## 4. Module responsibilities & interfaces

All modules are actors or actor-owned; `FlattenCore` compiles under Swift 6 strict concurrency.

### 4.1 CatalogKit — *the product core*

- `LrcatReader`: opens a **snapshot copy** of the `.lrcat` (`immutable=1`; copy first if LR holds the lock — detect via `.lock` file). Parses `Adobe_images` (rating, colorLabels, pick), `AgLibraryFile/Folder/RootFolder` (paths), `AgLibraryCollection`+`AgLibraryCollectionImage`, `AgLibraryKeyword` joins, develop-edits presence. Schema versions are detected from `Adobe_variablesTable`; each supported version has a golden-fixture test; unknown versions degrade to "paths + whatever columns still resolve" or full XMP fallback, with an explicit capability report surfaced to the UI.
- `XmpReader`: sidecar + embedded XMP packet parsing (`xmp:Rating`, `xmp:Label`, Lightroom's `lr:` collections/hierarchical keywords, Photo Mechanic/Bridge conventions). One parser, per-app label-name normalization tables.
- `C1Reader` (Phase 5): Capture One `.cocatalogdb` SQLite parse for ratings/color tags; falls back to XMP where C1 was set to write it.
- `Reconciler` + `PrecedenceResolver` as in §3.
- Output: writes `rating_records`, publishes `EffectiveRating` via IndexStore queries.

### 4.2 ScanKit

- Recursive discovery under security-scoped bookmarks; RAW extension routing table; RAW+JPEG pairing; sidecar detection.
- EXIF fast-path read (capture time, camera, serial) and embedded-preview extraction → thumbnail cache + `content_key`.
- Incremental rescan: FSEvents stream per source + mtime/size comparison; catalog files themselves are watched too (LR catalog changed → re-ingest prompt/auto).

### 4.3 RulesKit

- A `Rule` AST (criterion, operator, value) with ALL/ANY/NONE groups, serialized as JSON (presets are just saved ASTs).
- Compiles to a single SQL query over `images ⋈ effective_ratings` (materialized as a view refreshed on ingest) — this is how "filter recompute over 100k items < 100 ms" is met: the filter engine is SQLite, not Swift loops.
- Every evaluation returns `(matched, protected, conflicted, offline)` partitions plus aggregate bytes, feeding the live header counts.

### 4.4 RenderKit

- `Decoder`: ImageIO/Core Image RAW path, libraw fallback behind the same protocol; per-(format, camera) routing table.
- `Encoder`: HEIC/JPEG via ImageIO+VideoToolbox; JXL/AVIF behind the same protocol (Phase 6).
- `MetadataGrafter`: copies EXIF/IPTC/XMP wholesale, then **overlays the EffectiveRating** into the output's XMP (rating/label/flag), so the flattened file carries the catalog's verdict forward even if the catalog is later lost. File timestamps carried over.
- `SizeModel`: samples K real encodes per (camera, format) cluster to fit the estimator used in live savings counts.

### 4.5 PipelineKit

- `FlattenPlan` (value type): frozen item list + settings + originals policy + destination — what the Plan sheet renders and the user confirms. Plans are immutable once confirmed; rule changes after confirmation don't shift the ground.
- `BatchRunner` (actor): work-stealing pool sized to performance cores; per-item state machine:

```
pending → decoding → encoding → grafting → verifying → finalizing → done
                                                  ↘ failed (original untouched)
```

- **Crash-safe finalize order** (§1 problem 3): encode to temp file in destination volume → fsync → verify (decode-back, dimensions, metadata presence, optional SSIMULACRA2 gate) → journal intent → atomic rename into place → journal "output committed" → only then move/trash originals per ladder rung → journal "original finalized". On relaunch after crash, JournalKit replays: committed outputs with un-finalized originals resume; un-committed temps are swept.
- Cancel/pause/resume; battery + Low Power Mode policy hooks.

### 4.6 JournalKit

- Append-only per-batch journal (SQLite table + WAL) recording every mutation with enough info to reverse rungs 2–4 (restore from archive/Trash) and to render the Operation Log UI and CSV/JSON audit export.

### 4.7 flatten-cli (dev harness, not shipped)

```
flatten-cli scan <folder>
flatten-cli ingest <catalog.lrcat>
flatten-cli query '<rules.json>' --counts
flatten-cli plan  '<rules.json>' --format heic --quality 0.8 --originals archive:<path>
flatten-cli run   <plan-id> [--dry-run]
```

Every phase below has a CLI-demonstrable exit criterion. This is also the integration-test entry point in CI.

---

## 5. Concurrency & performance model

- `IndexStore`: single writer actor, snapshot reads via GRDB database pool; UI reads never block ingest.
- Scanning, catalog ingest, thumbnailing, and encoding are separate task groups with independent throttles; thumbnail decode priority is driven by grid visibility (scroll position → priority queue).
- Grid: AppKit `NSCollectionView` (or CALayer-backed custom view, decided by M-phase prototype) fed by the thumbnail cache; SwiftUI everywhere else via `@Observable` stores over IndexStore queries.
- Targets restated from SPEC §6.8; the two that shape design are *filter < 100 ms @ 100k* (met by SQL, §4.3) and *scan ≥ 500 img/s* (met by embedded-preview fast path, no full RAW decode at scan time).

---

## 6. Build sequence

Vertical slices, each ending in something runnable and testable. The catalog join ships in Phase 1; pixels don't move until Phase 3; the UI doesn't start until the engine is trustworthy. Durations assume ~1 experienced developer equivalent; phases 4–5 parallelize with a second contributor if available.

### Phase 0 — Foundations (1 wk)
Repo, `FlattenCore` SPM package, strict concurrency baseline, GRDB + IndexStore schema/migrations, `flatten-cli` skeleton, CI (macOS runner, fixture download step).
**Exit:** `flatten-cli scan ~/Pictures/test` populates `images` with EXIF fast-path fields and thumbnails.

### Phase 1 — Catalog ingestion & the join (3 wks) ← *the product core, built first*
- Fixture library: real `.lrcat` files across LR versions (LR 11–14 schemas), plus synthetic catalogs generated for edge cases (renamed volumes, offline drives, moved folders, RAW+JPEG, ambiguous relinks).
- `LrcatReader`, `XmpReader` (sidecar + embedded), `Reconciler` with the three-tier match strategy, `PrecedenceResolver`, conflict detection.
- **Exit:** `flatten-cli ingest catalog.lrcat` then `flatten-cli query` answers "all images unrated in LR and older than 2024" against a fixture tree with 100% precision on the fixture truth table; unmatched-on-both-sides reports work; conflicts detected. This phase carries the largest unit-test suite in the repo and it is the gate for everything after.

### Phase 2 — Rules engine & dry-run economics (1.5 wks)
- RulesKit AST → SQL compilation, ALL/ANY/NONE groups, presets as JSON, override pins.
- SizeModel sampling encoder (HEIC only at this point — enough to estimate).
- **Exit:** `flatten-cli plan --dry-run` prints the SPEC header line ("2,341 imgs · 96.4 GB → est. 7.1 GB") within ±10% of a subsequent real run on the benchmark corpus; 100k-row filter benchmark < 100 ms.

### Phase 3 — The pipeline, safely (3 wks)
- RenderKit decode/encode (ImageIO path; HEIC + JPEG), MetadataGrafter with rating overlay, verification pass.
- PipelineKit BatchRunner with crash-safe finalize ordering; JournalKit; ladder rungs 1–3 (dry-run / alongside / archive). Trash/delete rungs deliberately deferred — the engine earns them in Phase 7.
- Kill-test suite: `kill -9` the CLI at randomized pipeline points × 1,000 iterations; invariant checked after each: *no original modified without a verified, committed output*.
- **Exit:** end-to-end CLI flatten of a 5k-image fixture, resumable after forced crash, journal restores archive rung completely.

### Phase 4 — App shell & visual review (4 wks)
- SwiftUI app: sources sidebar (bookmarks, lrcat drop), rule builder UI over RulesKit, live counts header, protected-chip.
- Thumbnail grid (AppKit-backed) with amber/green fate edges, rating/flag/label badges, conflict badge; loupe with EXIF panel; provenance inspector showing every `Claim` behind an EffectiveRating.
- Plan sheet + batch progress UI + Operation Log UI over JournalKit.
- **Exit:** the primary use case end-to-end in-app: drop an `.lrcat`, filter "unrated ∧ not picked ∧ older than 6 months", visually review, flatten to HEIC with originals archived, restore the batch from the log.

### Phase 5 — Multi-catalog breadth (2 wks)
- Per-app XMP conventions hardened (Capture One, Bridge, darktable, Photo Mechanic fixture files), custom LR label-name mapping, `C1Reader` catalog parse, precedence-order settings UI, conflict-review filter preset.
- **Exit:** fixture matrix (4 apps × ratings/flags/labels) fully green; conflicting-sources workflow demonstrated.

### Phase 6 — Quality & trust surfaces (2.5 wks)
- Compare slider (before/after wipe + 2-up @100%), quality-slider live anchor crop, perceptual-target mode (SSIMULACRA2 search), JXL/AVIF encoders, lossy-DNG spike (go/no-go per SPEC open question #1).
- libraw fallback wiring + routing table.
- **Exit:** compare slider at 60 fps on 45 MB RAWs; perceptual mode hits target score on the calibration corpus.

### Phase 7 — Hardening & ship (3 wks)
- Trash rung, then typed-confirm delete rung — gated on kill-test suite still green and beta telemetry from rungs 1–3.
- LR relink report (same-basename output + per-batch relink guide), reporting/lifetime stats, onboarding tour, localization, sandbox audit, notarization + MAS submission, Sparkle for direct build.
- **Exit:** v1.0 release candidate.

**Total: ~20 weeks** to RC, consistent with SPEC's 22-week envelope with slack.

### Sequencing rationale (what's deliberately *not* early)

- **No UI until Phase 4**: the join engine's correctness is provable headlessly; UI built on a wrong data model is the expensive mistake this ordering avoids.
- **No destructive rungs until Phase 7**: archive-only through the whole beta builds the safety evidence (journal replay stats, kill tests) that justifies enabling Trash/delete.
- **HEIC-only until Phase 6**: one gold-path codec keeps Phases 2–4 focused on the flow, not the format zoo.

---

## 7. Testing strategy (summary)

| Layer | Approach |
|---|---|
| CatalogKit | Golden fixtures per LR schema version + per-XMP-dialect; truth-table precision tests; fuzzed/corrupt catalog inputs must fail closed (no join → no flatten) |
| Reconciler | Property tests over synthetic volume/rename/move scenarios; ambiguity must yield "unmatched," never a guess |
| PipelineKit | kill -9 crash matrix; power-loss simulation via forced unmount of a disk image mid-finalize |
| RulesKit | AST↔SQL round-trip tests; 100k-row perf benchmark in CI |
| End-to-end | flatten-cli scenarios in CI on fixture corpus; app-level UI tests for the Phase 4 exit flow |
| Beta | Archive-rung-only public beta; opt-in anonymized journal stats (batch sizes, failure reasons, schema versions seen in the wild) |

---

## 8. Decisions needed before Phase 0

1. **GRDB vs. raw SQLite** — recommended: GRDB (migrations, value observation for live UI counts). Low risk.
2. **Grid technology spike** — 2-day prototype of NSCollectionView vs. custom CALayer wall at 100k items, decided before Phase 4, doesn't block Phases 0–3.
3. **Fixture acquisition** — need real `.lrcat` files across LR 11–14 (own catalogs + community-donated anonymized catalogs; a script to strip previews/PII from donated catalogs is a Phase 0 deliverable).
4. **SSIMULACRA2 dependency** — vendored C++ vs. Swift port; spike in Phase 6, stub the protocol now.
