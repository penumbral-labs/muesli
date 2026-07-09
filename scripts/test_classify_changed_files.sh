#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT_DIR/scripts/classify_changed_files.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

run_case() {
  local name="$1"
  local files="$2"
  shift 2

  local output="$tmpdir/$name.out"
  printf '%s\n' "$files" | "$CLASSIFIER" > "$output"

  local expected
  for expected in "$@"; do
    if ! grep -qx "$expected" "$output"; then
      echo "FAIL $name: expected '$expected'"
      echo "Actual output:"
      cat "$output"
      exit 1
    fi
  done
}

run_case readme_docs_only \
  "README.md" \
  "docs_only=true" \
  "full_ci=false" \
  "review_worthy=false"

run_case docs_report_only \
  "docs/reports/ci.md" \
  "docs_only=true" \
  "full_ci=false" \
  "review_worthy=false"

run_case native_source \
  "native/MuesliNative/Sources/App.swift" \
  "app_source=true" \
  "full_ci=true" \
  "review_worthy=true"

run_case sponsor_asset \
  "assets/sponsors/acme.svg" \
  "docs_only=true" \
  "site_or_metadata=true" \
  "full_ci=false"

run_case bundled_asset \
  "assets/AppIcon.iconset/icon_512x512.png" \
  "app_source=true" \
  "full_ci=true" \
  "review_worthy=true"

run_case ci_workflow \
  ".github/workflows/ci.yml" \
  "workflow=true" \
  "ci_config=true" \
  "full_ci=true" \
  "review_worthy=true"

run_case non_ci_workflow \
  ".github/workflows/claude.yml" \
  "workflow=true" \
  "ci_config=false" \
  "full_ci=false" \
  "workflow_ci=true" \
  "review_worthy=true"

run_case release_script \
  "scripts/build_native_app.sh" \
  "release_surface=true" \
  "full_ci=true" \
  "review_worthy=true"

run_case unknown_path \
  "tools/new-helper.sh" \
  "unknown=true" \
  "full_ci=true" \
  "review_worthy=true"

run_case appcast_metadata \
  "docs/appcast.xml" \
  "release_surface=true" \
  "site_or_metadata=true" \
  "full_ci=true"

echo "classifier tests passed"
