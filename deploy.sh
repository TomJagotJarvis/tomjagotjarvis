#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

export AWS_PAGER=""

HUGO_BIN=${HUGO_BIN:-hugo}
AWS_BIN=${AWS_BIN:-aws}
STATE_DIR="$ROOT/.deploy"
BUILD_MARKER="$STATE_DIR/build-ready"

IMMUTABLE_CACHE='public,max-age=31536000,immutable'
MUTABLE_CACHE='public,max-age=0,s-maxage=300,must-revalidate'
OTHER_CACHE='public,max-age=86400'

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

touch_generated_images() {
  [ -d public/originals ] || return 0
  count=$(find public/originals -type f \( \
    -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
    -iname '*.webp' -o -iname '*.avif' \
  \) | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    find public/originals -type f \( \
      -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o \
      -iname '*.webp' -o -iname '*.avif' \
    \) -exec touch {} +
  fi
  printf 'Marked %s generated image(s) for upload.\n' "$count"
}

run_transfer() {
  printf '+ aws'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
  "$AWS_BIN" "$@"
}

run_transfer_with_mode() {
  if [ "$DRY_RUN" -eq 1 ]; then
    run_transfer "$@" --dryrun
  else
    run_transfer "$@"
  fi
}

run_cache_class_syncs() {
  destination="s3://$BUCKET"

  immutable_filters=(
    --exclude '*'
    --include 'css/*.css'
    --include 'originals/*_hu_*.jpg'
    --include 'originals/*_hu_*.jpeg'
    --include 'originals/*_hu_*.png'
    --include 'originals/*_hu_*.webp'
    --include 'originals/*_hu_*.avif'
  )
  mutable_filters=(
    --exclude '*'
    --include '*.html'
    --include '*.xml'
    --include 'robots.txt'
  )
  other_filters=(
    --exclude '*.html'
    --exclude '*.xml'
    --exclude 'robots.txt'
    --exclude 'css/*.css'
    --exclude 'originals/*_hu_*.jpg'
    --exclude 'originals/*_hu_*.jpeg'
    --exclude 'originals/*_hu_*.png'
    --exclude 'originals/*_hu_*.webp'
    --exclude 'originals/*_hu_*.avif'
  )

  sync_flags=(--delete --no-progress)
  run_transfer_with_mode s3 sync public/ "$destination" "${sync_flags[@]}" \
    --cache-control "$IMMUTABLE_CACHE" "${immutable_filters[@]}"
  run_transfer_with_mode s3 sync public/ "$destination" "${sync_flags[@]}" \
    --cache-control "$MUTABLE_CACHE" "${mutable_filters[@]}"
  run_transfer_with_mode s3 sync public/ "$destination" "${sync_flags[@]}" \
    --cache-control "$OTHER_CACHE" "${other_filters[@]}"
}

invalidate_cloudfront() {
  printf 'CloudFront invalidation (%s): /*\n' "$DIST_ID"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY RUN: no CloudFront invalidation was created.\n'
    return
  fi
  "$AWS_BIN" cloudfront create-invalidation \
    --distribution-id "$DIST_ID" \
    --paths '/*' >/dev/null
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

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
else
  die '.env file not found.'
fi
: "${BUCKET:?BUCKET not set in .env}"
: "${DIST_ID:?DIST_ID not set in .env}"

# Hugo may restore generated files with old cache timestamps. Touching only the
# generated images makes the following sync upload the ImageOptim result without
# hashes, manifests or a separate staging directory. The trade-off is that all
# generated images are uploaded on each occasional deployment.
touch_generated_images

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN: previewing S3 sync and CloudFront invalidations.\n'
else
  printf 'Deploying the prepared public/ output.\n'
fi

run_cache_class_syncs
invalidate_cloudfront

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN complete. No S3 objects or CloudFront resources were changed.\n'
else
  printf 'Deploy complete. Cache metadata applied and invalidations sent.\n'
fi
