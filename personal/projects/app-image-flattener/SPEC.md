# Flatten — Product & Technical Specification

**A macOS app for photographers who need to reclaim hard drive space by flattening RAW images into compressed formats — safely, visually, and in bulk.**

| | |
|---|---|
| Working name | **Flatten** (alternates: Cull, Distill, Shrinkwrap) |
| Platform | macOS 14 (Sonoma) and later, Apple Silicon–optimized, Intel supported |
| Distribution | Mac App Store + notarized direct download (Sparkle updates) |
| Tech stack | Swift 6, SwiftUI + AppKit interop, Core Image / ImageIO, Metal |
| Status | Draft v0.1 — 2026-08-18 |

---

## 1. Problem Statement

Professional and enthusiast photographers accumulate terabytes of RAW files (CR3, NEF, ARW, RAF, ORF, DNG, …). The overwhelming majority of these images will never be edited again — they are B-roll, near-duplicates, rejected frames, or delivered work that only needs to remain viewable. Yet RAW files cost 25–120 MB each, and photographers keep them "just in case" because:

1. **Deleting feels irreversible.** There is no comfortable middle ground between "keep the 45 MB RAW" and "lose the shot forever."
2. **Existing tools don't respect their workflow.** The decision of what to keep is already encoded in Lightroom star ratings, flags, and color labels — but Finder-level compression tools can't see that metadata.
3. **Bulk conversion tools are scary.** Command-line converters and generic batch apps give no visual confirmation of what will happen, no quality preview, and no undo.

**Flatten's core promise:** *"Keep your 5-star RAWs. Flatten everything else to a fraction of the size. See exactly what you're doing before you do it."*

---

## 2. Target Users

| Persona | Description | Primary need |
|---|---|---|
| **The Wedding/Event Pro** | Shoots 3–5k frames per event, delivers 600. Archives everything. 20+ TB of drives. | Flatten all non-picked frames after delivery; keep picks as RAW. |
| **The Serious Enthusiast** | 10 years of Lightroom catalogs, 4 TB drive nearly full. | Reclaim space without buying another drive; trust the tool not to destroy memories. |
| **The Studio Manager** | Manages archives for multiple shooters. | Repeatable rules ("flatten anything unrated older than 1 year"), audit trail, dry runs. |

Non-goals: this is not a culling tool, not a RAW editor, not a DAM/catalog replacement. It reads catalogs and sidecars; it never writes to a Lightroom catalog beyond optional path updates (see §6.6).

---

## 3. Core Concepts

### 3.1 Flattening

"Flattening" = rendering a RAW file to a compressed, ready-to-view format and (optionally) removing the original. Supported output formats:

| Format | Use case | Typical size vs. 45 MB RAW |
|---|---|---|
| **HEIC (10-bit, P3)** | Default. Best quality/size on Apple platforms. | 2–6 MB |
| **JPEG (quality slider)** | Maximum compatibility. | 4–10 MB |
| **JPEG XL** | Forward-looking; optional lossless-JPEG recompression mode. | 3–8 MB |
| **Lossy DNG** | Stays "RAW-like" in Lightroom; keeps highlight recovery headroom. | 8–14 MB |
| **AVIF** | Web-archival option. | 2–5 MB |

Every flatten operation preserves:
- Full EXIF (capture data, lens, GPS)
- IPTC/XMP (keywords, captions, copyright, **ratings, labels, flags**)
- Original file dates (creation/modification timestamps carried over)
- Optionally the develop-settings XMP block, embedded for provenance

### 3.2 The Safety Ladder

Users choose what happens to originals, from timid to committed:

1. **Preview only (dry run)** — compute savings, touch nothing.
2. **Flatten alongside** — write compressed file next to original; original untouched.
3. **Flatten & archive originals** — move originals to a designated "cold" volume/folder, mirrored structure.
4. **Flatten & trash** — originals go to macOS Trash (recoverable until emptied).
5. **Flatten & delete** — immediate removal. Requires typed confirmation, off by default, and gated behind a completed verification pass (§6.5).

### 3.3 Sources

- **Folder scan** — point at any folder/volume; recursive discovery of RAW formats via ImageIO + libraw fallback.
- **Lightroom Classic catalog (.lrcat)** — read-only SQLite parse: ratings, pick/reject flags, color labels, collections, keywords, edit history presence ("has develop adjustments").
- **XMP sidecars** — ratings/labels from any XMP-writing app (Capture One, Bridge, darktable, Photo Mechanic).
- **Capture One catalogs/sessions** — read-only parse of ratings and color tags (v1.x if schema stability allows; otherwise via XMP).
- **Apple Photos library** — via PhotoKit: favorites, albums, keywords (flattening happens on exported originals; library edit-in-place is out of scope for v1).

---

## 4. Feature Requirements

### 4.1 Discovery & Scanning

- Drag-and-drop folders, volumes, or `.lrcat` files onto the app or Dock icon.
- Background scanner with live progress (files found, RAW GB total, thumbnails streaming in as discovered).
- Detects RAW+JPEG pairs and pre-existing sidecar XMPs; pairs are treated as one logical image.
- Duplicate detection (same capture: content hash of embedded preview + capture time + camera serial) surfaced as a filter, not auto-acted-on.
- Handles offline/disconnected volumes gracefully: items shown as "offline," excluded from operations, remembered for reconnection.
- Scan index persisted locally (SQLite) so re-opening a source is instant; rescans are incremental (FSEvents + mtime).

### 4.2 Filtering (the heart of the app)

A **filter bar + rule builder** that combines any of:

| Criterion | Values / operators |
|---|---|
| **Star rating** | =, ≥, ≤, unrated (from LR catalog, XMP, or embedded XMP) |
| **Flag** | Picked / Rejected / Unflagged |
| **Color label** | Red/Yellow/Green/Blue/Purple/None (with LR custom label-name mapping) |
| **Has develop edits** | Yes/No (LR catalog only) |
| **In collection** | Member of / not member of (LR collections & smart collections) |
| **Keywords** | contains / not contains |
| **Capture date** | before / after / range / older than N months |
| **File date** | same operators |
| **Camera / lens** | picker populated from scan |
| **File type** | per-RAW-format |
| **File size** | > / < threshold |
| **Dimensions / MP** | > / < threshold |
| **Duplicates** | is duplicate of a kept image |
| **Path** | folder subtree include/exclude |

- Rules compose with ALL/ANY/NONE groups, nestable one level (mirrors Lightroom smart collection UX so it feels instantly familiar).
- **Live counts:** every rule edit instantly updates "2,341 images · 96.4 GB → est. 7.1 GB (saves 89.3 GB)" in the header. Estimation uses sampled real conversions (§6.4), not guesses.
- **Presets:** ship with starter presets — "Unrated older than 6 months," "Rejected frames," "Everything except Picks & ≥4★." User presets are saveable, nameable, and exportable.
- **Inverse always visible:** a persistent "what's protected" chip shows the count of images the current rule set will *not* touch, one click to view them.

### 4.3 Visual Review (grid & loupe)

- **Grid view**: GPU-accelerated thumbnail wall (embedded RAW previews, so no decode cost), 60 fps scrolling over 100k+ items, size slider, sections by folder or capture date.
- Badges on every thumbnail: rating stars, flag, color label edge, file format tag, size, and a **"will flatten" / "protected" state color** (amber vs. green edge) so the consequence of the current rules is visible at a glance across the whole grid.
- **Loupe view** (spacebar): full-screen single image with EXIF panel, 100% zoom, and arrow-key navigation.
- **Compare slider**: in loupe, a draggable before/after wipe between original RAW render and the compressed candidate at current settings, plus 2-up side-by-side at 100%. This is the trust-building moment of the app.
- Per-image overrides: right-click → "Always protect" / "Always flatten" pins that survive rule changes (shown with a pin badge).
- Quick-look style keyboard flow: `P` protect, `F` flatten, `0–5` filter-jump, `⌘Z` undo any override.

### 4.4 Compression Settings

- Global default profile + per-batch override.
- Quality slider with **live visual anchor**: a magnified crop of a representative image (auto-picked: high-frequency detail, skin tone if faces detected) re-encodes as you drag.
- Advanced disclosure: chroma subsampling, bit depth, color space (P3/sRGB/AdobeRGB pass-through), max long-edge resize (off by default), strip-GPS toggle (default: keep).
- Perceptual target mode: "Match visual quality" (Butteraugli/SSIMULACRA2 target) as an alternative to a fixed quality number — the encoder searches for the smallest file meeting the target per image.

### 4.5 The Flatten Operation

- Explicit, reviewable **Plan sheet** before anything runs: N files, source formats breakdown, destination format, originals policy (Safety Ladder rung), estimated savings, estimated time, destination free-space check.
- Batch runs as a background `Operation` pipeline: decode (ImageIO/libraw) → render → encode (HEIC/JXL/AVIF via VideoToolbox & bundled encoders) → metadata graft (exiftool-equivalent via bundled library) → verify → finalize originals.
- Fully resumable and cancelable mid-run; already-completed items stay done; per-item failures are collected, never abort the batch.
- Power-aware: pause on battery < 20% (configurable), Low Power Mode respect, optional "run overnight" scheduling.
- Progress UI: overall bar + live per-worker thumbnails, running savings counter ("11.2 GB reclaimed so far"), ETA.

### 4.6 Verification & Undo

- Post-encode verification per image: decode-back check, dimension match, metadata presence check, and optional structural-similarity score gate — an image failing verification keeps its original regardless of ladder rung.
- **Operation Log**: every batch is journaled (what was created, what was moved/trashed, where). The log view offers "Reveal originals," "Restore batch" (for archive/trash rungs), and CSV/JSON export for studio audit trails.
- Trash/archive rungs are fully reversible from within the app until the user empties Trash or deletes the archive.

### 4.7 Catalog Reconnection (Lightroom-aware output)

- Optional: when flattening images that live in an LR catalog, write the compressed file with the **same base filename** next to the original's location so LR's "find missing photos" relink is one click.
- Ships with a short built-in guide (and a generated per-batch relink report) for updating LR to point at flattened files. Direct `.lrcat` writing is deferred to v2 behind an explicit "catalog is closed & backed up" gate.

### 4.8 Reporting

- End-of-batch summary: space saved, before/after totals, failures with reasons, one-click "Reveal in Finder."
- Lifetime stats screen ("You've reclaimed 1.4 TB with Flatten") — shareable card.

---

## 5. UX / UI Design

### 5.1 Design language

- Native macOS through and through: SwiftUI, SF Symbols, vibrancy sidebars, full dark/light support (photographers live in dark mode — dark is the design-first target, near-black `#161618` surfaces so images dominate).
- Layout is a familiar three-pane DAM shape so pros feel at home immediately:

```
┌────────────┬──────────────────────────────────────────┬─────────────┐
│  SOURCES   │  FILTER BAR  [Unrated ×][>6mo ×][+ Rule] │  INSPECTOR  │
│            │  2,341 imgs · 96.4 GB → 7.1 GB  ● 412 protected        │
│  ▸ Volumes ├──────────────────────────────────────────┤  Selected   │
│  ▸ LR Cat  │                                          │  image      │
│  ▸ Presets │        THUMBNAIL GRID                    │  metadata,  │
│  ▸ History │        (amber = will flatten,            │  override   │
│            │         green = protected)               │  pins,      │
│            │                                          │  est. size  │
│            ├──────────────────────────────────────────┤             │
│            │  ⚡ Flatten 1,929 images…   est. −89.3 GB │             │
└────────────┴──────────────────────────────────────────┴─────────────┘
```

- The primary action button always states its consequence in numbers: **"Flatten 1,929 images · save ~89.3 GB."** Never a bare "Run."
- Motion: thumbnails animate between protected/flatten states when rules change — the user *sees* the rule's effect ripple across the grid.
- Empty states teach: first launch shows a drop target with the three source types and a 30-second interactive tour using bundled sample RAWs.

### 5.2 Trust-first UX principles

1. **Nothing destructive is ever one click away.** Plan sheet → confirm; delete rung requires typing the image count.
2. **Consequences are always visible** (amber/green edges, protected-count chip, live savings math).
3. **Every batch is a journal entry** that can be inspected and, where the ladder allows, reversed.
4. **The compare slider is one keystroke away** at all times — quality doubt is resolved by looking, not by faith.

### 5.3 Accessibility & polish

- Full keyboard operability; VoiceOver labels on grid items including rating/flag/state.
- Localizations at launch: EN, DE, JA, FR, ES (photography's biggest markets).
- Haptic/audio-free by default; subtle completion notification via UserNotifications with savings figure.

---

## 6. Technical Architecture

### 6.1 App structure

- **Swift 6 / SwiftUI** app with strict concurrency; AppKit interop for the grid (a custom `NSCollectionView`-backed, Metal-textured thumbnail layer — SwiftUI grids don't hit 60 fps at 100k items yet).
- Modules (SPM local packages): `ScanKit` (discovery/indexing), `CatalogKit` (lrcat/XMP/C1 parsers), `RenderKit` (decode/encode), `RulesKit` (filter engine), `JournalKit` (operation log/undo), `UIComponents`.

### 6.2 RAW decoding

- Primary: Apple ImageIO / Core Image RAW pipeline (fast, GPU, wide camera support).
- Fallback: bundled **libraw** for formats/bodies ImageIO lags on; per-format routing table updated with app releases.
- Embedded-preview fast path for thumbnails and estimates (no full decode until needed).

### 6.3 Encoding

- HEIC/AVIF: VideoToolbox hardware encode where available, software fallback.
- JPEG: ImageIO with mozjpeg-class tuning; JPEG XL via bundled `libjxl`.
- Metadata graft: bundled metadata library (no exiftool/Perl dependency) copying EXIF/IPTC/XMP wholesale, then overlaying rating/label from catalog if the catalog is "truthier" than the file (user toggle, default on).

### 6.4 Savings estimation

- On scan, sample K images per (camera, format) cluster, run real encodes at current settings, fit a size model; live header numbers come from the model, refined as real batch data arrives. Accuracy target: ±10%.

### 6.5 Integrity

- Verification pass per §4.6; batch-level checksum manifest written into the Operation Log.
- All original-file mutations (move/trash/delete) happen only after the flattened file is fully written, fsynced, and verified — crash-safe ordering, journaled two-phase finalize.

### 6.6 Lightroom catalog access

- `.lrcat` is SQLite: read-only open with `immutable=1` on a **copied snapshot** if the catalog is locked/open in LR. Parse `Adobe_images` (rating, colorLabels, pick), `AgLibraryFile`/`AgLibraryFolder`/`AgLibraryRootFolder` (paths), `AgLibraryCollection` + content tables, keyword tables. Schema-version detection with graceful degradation (unknown schema → offer XMP-sidecar mode).
- Never write to the catalog in v1.

### 6.7 Sandbox & permissions

- App Sandbox with security-scoped bookmarks for user-granted folders/volumes; bookmarks persisted for re-launch access.
- Full Disk Access not required; clear in-app explanation whenever a grant is requested.
- Mac App Store build: trash rung uses `NSWorkspace.recycle`; delete rung available. Direct build identical.

### 6.8 Performance targets

| Metric | Target |
|---|---|
| Scan rate (previews) | ≥ 500 images/sec on Apple Silicon SSD |
| Grid scroll | 60 fps @ 100k items |
| Flatten throughput | ≥ 2 images/sec/perf-core (45 MB RAW → HEIC, M-series) |
| Filter recompute (100k items) | < 100 ms |
| Cold open of previously scanned source | < 1 s |

---

## 7. Monetization

- **Free tier:** full scanning, filtering, previews, dry runs, and up to 200 flattens/month — the trust-building funnel.
- **Flatten Pro:** one-time purchase **$49.99** (or $29.99/yr subscription with updates) — unlimited flattening, presets sync, JXL/AVIF, perceptual-target mode, studio audit exports.
- No accounts required; StoreKit 2 + direct-sale licensing (Paddle) for the notarized build.

---

## 8. Milestones

| Phase | Scope | Duration |
|---|---|---|
| **M1 — Core pipeline** | ScanKit, folder sources, HEIC/JPEG encode, metadata graft, verification, Plan sheet, rungs 1–3 | 6 wks |
| **M2 — Filtering & catalogs** | RulesKit UI, XMP sidecars, `.lrcat` parsing, presets, live estimates | 6 wks |
| **M3 — Visual review** | Metal grid, loupe, compare slider, overrides, dark-mode polish | 5 wks |
| **M4 — Safety & ship** | Journal/undo, trash/delete rungs, reporting, onboarding, localization, notarization, MAS review | 5 wks |
| **v1.0 launch** | | ~22 wks |
| **v2 candidates** | Capture One native, Apple Photos in-place, LR catalog relink-write, scheduled auto-flatten rules, NAS/SMB optimization, dupe auto-stacks | — |

---

## 9. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Data loss bug destroys user photos | Safety Ladder defaults, two-phase journaled finalize, verification gate, delete rung gated & typed-confirm; beta with archive-only rungs enabled |
| Adobe changes `.lrcat` schema | Schema-version detection, XMP fallback path, fast-follow updates |
| ImageIO can't decode a new body's RAW | libraw fallback + routing table; "unsupported — skipped, original untouched" is the failure mode |
| Users distrust quality loss | Compare slider, perceptual-target mode, free tier lets them verify on their own images before paying |
| MAS review friction on file deletion | Trash-based flows, sandbox-clean design, direct-sale build as backstop |

---

## 10. Open Questions

1. Should lossy DNG be in v1? It keeps Lightroom-native workflows intact but Adobe's DNG SDK licensing and conversion speed need a spike.
2. Perceptual-target default (SSIMULACRA2 score) — needs a calibration study across camera clusters.
3. Minimum macOS: 14 vs. 15 (15 unlocks newer SwiftUI grid perf — decide after M3 prototype).
4. Studio/multi-seat licensing demand — validate during beta before building.
