#!/usr/bin/env bash
# Import .lrcat catalog backups into the test fixture corpus and record each
# one's schema version (pre-Phase 0 decision #3: fixtures come from Paul's
# own backups).
#
# Usage: scripts/import-fixtures.sh <backup1.lrcat> [backup2.lrcat ...]
#
# Copies each catalog into Fixtures/lrcat/ and appends to
# Fixtures/lrcat/manifest.tsv (filename, Adobe_DBVersion, size, imported-at).
# Catalog files themselves are gitignored; the manifest is committed so CI can
# assert which schema versions the corpus covers.

set -euo pipefail

cd "$(dirname "$0")/.."
DEST="Fixtures/lrcat"
MANIFEST="$DEST/manifest.tsv"
mkdir -p "$DEST"

if ! command -v sqlite3 >/dev/null; then
  echo "error: sqlite3 CLI is required" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  printf 'filename\tadobe_db_version\tbytes\timported_at\n' > "$MANIFEST"
fi

for src in "$@"; do
  if [[ ! -f "$src" ]]; then
    echo "skip (not a file): $src" >&2
    continue
  fi
  name="$(basename "$src")"
  cp -n "$src" "$DEST/$name" || true

  version="$(sqlite3 "file:$DEST/$name?immutable=1" \
    "SELECT value FROM Adobe_variablesTable WHERE name='Adobe_DBVersion';" \
    2>/dev/null || echo 'unknown')"
  bytes="$(wc -c < "$DEST/$name" | tr -d ' ')"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Replace any existing manifest row for this filename, then append.
  grep -v "^$name	" "$MANIFEST" > "$MANIFEST.tmp" || true
  mv "$MANIFEST.tmp" "$MANIFEST"
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$bytes" "$stamp" >> "$MANIFEST"

  echo "imported: $name (Adobe_DBVersion=$version, $bytes bytes)"
done

echo ""
echo "Corpus now covers these schema versions:"
tail -n +2 "$MANIFEST" | cut -f2 | sort -u
