# FlattenCore

Engine package for **Flatten** — see [../SPEC.md](../SPEC.md) and
[../ARCHITECTURE.md](../ARCHITECTURE.md).

## Status: Phase 2 (rules engine) — in progress

Done in Phase 2 so far:

- `RuleCompiler`: the rule AST compiles to a single SQL predicate over
  images ⋈ rating_records ⋈ overrides — effective ratings resolve by
  precedence *inside SQL*, conflicted images are auto-protected by default,
  and protect/flatten pins override the rule in both directions.
- `IndexStore.evaluate`: matched/protected counts and bytes in one query.
- `flatten-cli query rules.json [--samples N] [--include-conflicts]` is live.

Still open in Phase 2: size-model sampling (needs Phase 3 encoders), the
100k-row perf benchmark, `flatten-cli plan`.

Done in Phase 1:

- `LrcatReader`: read-only Lightroom Classic catalog parser over a snapshot
  copy — ratings, pick/reject flags, color labels, capture times, keywords,
  collections, develop-history presence, full paths. Column/table presence is
  detected per catalog; unknown schemas degrade or fail closed.
- `XmpReader`: XMP sidecar parser (attribute and element forms, dc:subject,
  lr:hierarchicalSubject).
- `Reconciler`: tier-1 exact path (case-insensitive) and tier-2 relink
  (filename + capture time, unique-only). Ambiguity never guesses. Tier 3
  (content) still to come.
- `LrcatIngestor` / `SidecarIngestor` / `RatingStore`: catalog → reconcile →
  rating_records claims → resolved `EffectiveRating`, with ingest reports
  (matched exact/relinked, unmatched samples, unknown-to-any-catalog count).
- `flatten-cli ingest <catalog.lrcat>` and `flatten-cli ingest <folder>`
  (sidecars) are live.
- Synthetic `.lrcat` fixture builder + reader/reconciler/ingest/conflict tests.

Still open in Phase 1: content-tier reconciliation, real-catalog fixture
matrix (run `scripts/import-fixtures.sh` on your backups), custom label-name
mapping.

Done in Phase 0:

- `FlattenCore` SPM package, Swift 6 strict concurrency, macOS 14+.
- `IndexStore` on **GRDB**: v1 schema (sources / images / rating_records /
  overrides) with migrations, single-writer actor.
- `ScanKit`: recursive RAW discovery, RAW+JPEG pairing, XMP sidecar detection,
  EXIF fast path via ImageIO (capture time, camera, serial, lens), embedded
  previews → thumbnail cache + content keys.
- `CatalogKit`: `Claim` / `EffectiveRating` model and the working
  `PrecedenceResolver` (lrcat > sidecar > C1 > embedded, conflict detection).
  Catalog readers land in Phase 1.
- `RulesKit`: rule AST with JSON round-trip (presets). SQL compilation lands
  in Phase 2.
- `RenderKit` / `PipelineKit` / `JournalKit`: type seams only (Phases 3+).
- `flatten-cli` with a working `scan` subcommand; `ingest`/`query`/`plan`/`run`
  stubbed to their phases.
- CI on a macOS runner (`.github/workflows/flatten-ci.yml` at the repo root).
- `scripts/import-fixtures.sh` — imports `.lrcat` backups into the fixture
  corpus and records schema versions.

## Build & run (macOS)

```sh
swift build
swift test
swift run flatten-cli scan ~/Pictures/test-shoot --workspace /tmp/flatten-ws
```

Phase 0 exit criterion: the `scan` command populates the `images` table with
EXIF fast-path fields and caches thumbnails.

macOS is the target and the CI platform of record. ImageIO-dependent paths are
gated behind `canImport(ImageIO)` with a `NullExifReader` fallback so the
pure-logic modules stay portable, but non-Apple platforms are not supported.
