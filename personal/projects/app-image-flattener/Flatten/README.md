# FlattenCore

Engine package for **Flatten** — see [../SPEC.md](../SPEC.md) and
[../ARCHITECTURE.md](../ARCHITECTURE.md).

## Status: Phase 0 (foundations)

Done in this phase:

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
