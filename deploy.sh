#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

HUGO_BIN=${HUGO_BIN:-hugo}
STATE_DIR="$ROOT/.deploy"
BUILD_MARKER="$STATE_DIR/build-ready"

DRY_RUN=0
BUILD_ONLY=0

usage() {
  cat <<'HELP'
Usage:
  ./deploy.sh --build-only
  ./deploy.sh --dry-run
  ./deploy.sh

Workflow:
  1. --build-only creates a clean Hugo build and stops.
  2. Optimise public/ in ImageOptim and wait for the app to finish.
  3. --dry-run previews uploads, deletions and invalidations.
  4. Run without options to deploy the prepared output.

Options:
  --build-only   Build public/ and stop without contacting AWS.
  --dry-run, -n  Preview S3 operations and invalidations without applying them.
  --help, -h     Show this help.
HELP
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

assert_public_is_deployable() {
  [ -d public ] || die 'public/ does not exist. Run ./deploy.sh --build-only first.'
  forbidden=$(find public -type f \( -name '.DS_Store' -o -name '*.bak' -o -name '*.bak.*' -o -name '*.tmp' \) -print | head -1)
  [ -z "$forbidden" ] || die "forbidden build artifact found: $forbidden"

  unfingerprinted_css=$(find public/css -type f -name '*.css' -print 2>/dev/null | grep -Ev '/[^/]+\.[0-9a-f]{16,}\.css$' | head -1 || true)
  [ -z "$unfingerprinted_css" ] || die "CSS is not fingerprinted and cannot be cached as immutable: $unfingerprinted_css"
}

record_build() {
  mkdir -p "$STATE_DIR"
  commit=$(git rev-parse HEAD 2>/dev/null || printf 'unversioned')
  printf 'commit=%s\nbuilt_at=%s\n' "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUILD_MARKER"
  touch "$BUILD_MARKER"
}

source_changed_after_build() {
  for entry in config.toml content layouts assets static data i18n themes; do
    if [ -f "$entry" ]; then
      [ "$entry" -nt "$BUILD_MARKER" ] && { printf '%s\n' "$entry"; return 0; }
    elif [ -d "$entry" ]; then
      changed=$(find "$entry" -type f \
        ! -name '.DS_Store' \
        ! -name '*.bak' \
        ! -name '*.bak.*' \
        ! -name '*.tmp' \
        -newer "$BUILD_MARKER" -print -quit)
      [ -n "$changed" ] && { printf '%s\n' "$changed"; return 0; }
    fi
  done
  return 1
}

validate_prepared_build() {
  [ -f "$BUILD_MARKER" ] || die 'no prepared build exists. Run ./deploy.sh --build-only first.'
  assert_public_is_deployable

  expected_commit=$(awk -F= '$1 == "commit" { print $2; exit }' "$BUILD_MARKER")
  current_commit=$(git rev-parse HEAD 2>/dev/null || printf 'unversioned')
  [ "$expected_commit" = "$current_commit" ] || die 'the Git commit changed after the build; rebuild before deploying.'

  changed_source=$(source_changed_after_build || true)
  [ -z "$changed_source" ] || die "site source changed after the build: $changed_source"
}

run_hugo_deploy() {
  # The one-time metadata migration is deliberately a direct Hugo command.
  # Normal wrapper use must remain incremental even if this variable is set in
  # the caller's shell.
  HUGO_DEPLOYMENT_FORCE=false "$HUGO_BIN" deploy --target production "$@"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-only) BUILD_ONLY=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

if [ "$BUILD_ONLY" -eq 1 ]; then
  [ "$DRY_RUN" -eq 0 ] || die '--dry-run is not used with --build-only.'
  printf 'Building a clean production site with Hugo...\n'
  "$HUGO_BIN" --minify --gc --cleanDestinationDir --panicOnWarning
  assert_public_is_deployable
  record_build
  printf 'Build recorded. Next:\n'
  printf '  open -a ImageOptim public/\n'
  printf 'Wait for ImageOptim to finish, then run:\n'
  printf '  ./deploy.sh --dry-run\n'
  exit 0
fi

validate_prepared_build

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN: comparing the prepared output with the production target.\n'
  run_hugo_deploy --dryRun
  printf 'DRY RUN complete. No S3 objects or CloudFront resources were changed.\n'
else
  printf 'Deploying the prepared public/ output with Hugo.\n'
  run_hugo_deploy
  printf 'Deploy complete.\n'
fi
