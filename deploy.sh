#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

export AWS_PAGER=""

HUGO_BIN=${HUGO_BIN:-hugo}
AWS_BIN=${AWS_BIN:-aws}
STATE_DIR=${DEPLOY_STATE_DIR:-"$ROOT/.deploy"}
BUILD_STATE="$STATE_DIR/build-state"
BUILD_MANIFEST="$STATE_DIR/build-public-manifest.tsv"
PREVIEW_STATE="$STATE_DIR/preview-state"

IMMUTABLE_CACHE='public,max-age=31536000,immutable'
MUTABLE_CACHE='public,max-age=0,s-maxage=300,must-revalidate'
OTHER_CACHE='public,max-age=86400'

DRY_RUN=0
BUILD_ONLY=0
SKIP_BUILD=0
REFRESH_METADATA=0

usage() {
  cat <<'HELP'
Usage:
  ./deploy.sh --build-only
  ./deploy.sh --skip-build --dry-run [--refresh-metadata]
  ./deploy.sh --skip-build [--refresh-metadata]

Workflow:
  1. --build-only creates a clean Hugo build and records its source state.
  2. Optimise public/ in ImageOptim and wait for the app to finish.
  3. --skip-build --dry-run previews the exact output and records its hash.
  4. --skip-build deploys only if source and output still match that preview.

Options:
  --build-only        Build public/ and stop without contacting AWS.
  --skip-build        Never invoke Hugo; require a current recorded build.
  --dry-run, -n       Use AWS dry runs and never create an invalidation.
  --refresh-metadata  Re-upload every object with the declared Cache-Control
                      policy. Intended only for the one-time metadata migration.
  --help, -h          Show this help.
HELP
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

state_value() {
  key=$1
  file=$2
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

hash_stream() {
  shasum -a 256 | awk '{print $1}'
}

file_metadata() {
  file=$1
  if stat -f '%z %m %c %i' "$file" >/dev/null 2>&1; then
    stat -f '%z %m %c %i' "$file"
  else
    stat -c '%s %Y %Z %i' "$file"
  fi
}

source_fingerprint() {
  list_file=$(mktemp "${TMPDIR:-/tmp}/hugo-deploy-sources.XXXXXX")

  for entry in config.toml content layouts assets static data i18n; do
    if [ -f "$entry" ]; then
      printf '%s\n' "$entry" >> "$list_file"
    elif [ -d "$entry" ]; then
      find "$entry" -type f \
        ! -name '.DS_Store' \
        ! -name '*.bak' \
        ! -name '*.bak.*' \
        ! -name '*.tmp' \
        -print >> "$list_file"
    fi
  done

  LC_ALL=C sort -u "$list_file" -o "$list_file"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in
      *.[jJ][pP][gG]|*.[jJ][pP][eE][gG]|*.[pP][nN][gG]|*.[wW][eE][bB][pP]|*.[aA][vV][iI][fF])
        printf 'asset %s %s\n' "$file" "$(file_metadata "$file")"
        ;;
      *)
        printf 'source %s %s\n' "$file" "$(shasum -a 256 "$file" | awk '{print $1}')"
        ;;
    esac
  done < "$list_file" | hash_stream
  rm -f "$list_file"
}

assert_public_is_deployable() {
  [ -d public ] || die 'public/ does not exist. Run ./deploy.sh --build-only first.'
  forbidden=$(find public -type f \( -name '.DS_Store' -o -name '*.bak' -o -name '*.bak.*' -o -name '*.tmp' \) -print | head -1)
  [ -z "$forbidden" ] || die "forbidden build artifact found: $forbidden"
  unfingerprinted_css=$(find public/css -type f -name '*.css' -print 2>/dev/null | grep -Ev '/[^/]+\.[0-9a-f]{16,}\.css$' | head -1 || true)
  [ -z "$unfingerprinted_css" ] || die "CSS is not fingerprinted and cannot be cached as immutable: $unfingerprinted_css"
}

write_public_manifest() {
  output=$1
  assert_public_is_deployable
  find public -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s\t%s\n' "$(shasum -a 256 "$file" | awk '{print $1}')" "${file#public/}"
  done > "$output"
}

public_fingerprint() {
  manifest_file=$(mktemp "${TMPDIR:-/tmp}/hugo-deploy-public.XXXXXX")
  write_public_manifest "$manifest_file"
  hash_stream < "$manifest_file"
  rm -f "$manifest_file"
}

record_build_manifest() {
  mkdir -p "$STATE_DIR"
  manifest_tmp=$(mktemp "$STATE_DIR/build-public-manifest.XXXXXX")
  write_public_manifest "$manifest_tmp"
  fingerprint=$(hash_stream < "$manifest_tmp")
  mv "$manifest_tmp" "$BUILD_MANIFEST"
  printf '%s\n' "$fingerprint"
}

write_build_state() {
  mkdir -p "$STATE_DIR"
  state_tmp=$(mktemp "$STATE_DIR/build-state.XXXXXX")
  commit=$(git rev-parse HEAD 2>/dev/null || printf 'unversioned')
  hugo_version=$($HUGO_BIN version | hash_stream)
  cat > "$state_tmp" <<EOF
STATE_VERSION=2
SOURCE_FINGERPRINT=$1
BUILD_PUBLIC_FINGERPRINT=$2
GIT_COMMIT=$commit
HUGO_VERSION_FINGERPRINT=$hugo_version
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  mv "$state_tmp" "$BUILD_STATE"
  rm -f "$PREVIEW_STATE"
}

validate_recorded_build() {
  [ -f "$BUILD_STATE" ] || die 'no recorded build exists. Run ./deploy.sh --build-only first.'
  [ -f "$BUILD_MANIFEST" ] || die 'the build manifest is missing. Run ./deploy.sh --build-only again.'
  [ "$(state_value STATE_VERSION "$BUILD_STATE")" = 2 ] || die 'unsupported deployment state; rebuild it.'
  expected_manifest=$(state_value BUILD_PUBLIC_FINGERPRINT "$BUILD_STATE")
  [ "$(hash_stream < "$BUILD_MANIFEST")" = "$expected_manifest" ] \
    || die 'the recorded build manifest does not match its build state; rebuild it.'
  expected_source=$(state_value SOURCE_FINGERPRINT "$BUILD_STATE")
  current_source=$(source_fingerprint)
  [ "$current_source" = "$expected_source" ] || die 'site sources changed after the recorded build; rebuild before deploying.'
  assert_public_is_deployable
}

target_fingerprint() {
  printf '%s\n%s\n' "$BUCKET" "$DIST_ID" | hash_stream
}

write_preview_state() {
  mkdir -p "$STATE_DIR"
  state_tmp=$(mktemp "$STATE_DIR/preview-state.XXXXXX")
  cat > "$state_tmp" <<EOF
STATE_VERSION=2
SOURCE_FINGERPRINT=$(state_value SOURCE_FINGERPRINT "$BUILD_STATE")
PUBLIC_FINGERPRINT=$1
TARGET_FINGERPRINT=$(target_fingerprint)
REFRESH_METADATA=$REFRESH_METADATA
TRANSFER_PLAN_FINGERPRINT=$2
PREVIEWED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  mv "$state_tmp" "$PREVIEW_STATE"
}

validate_preview_state() {
  [ -f "$PREVIEW_STATE" ] || die 'no matching dry-run preview exists; run with --skip-build --dry-run first.'
  [ "$(state_value STATE_VERSION "$PREVIEW_STATE")" = 2 ] || die 'unsupported preview state; run the dry run again.'
  [ "$(state_value SOURCE_FINGERPRINT "$PREVIEW_STATE")" = "$(state_value SOURCE_FINGERPRINT "$BUILD_STATE")" ] \
    || die 'the preview was made from a different build.'
  [ "$(state_value TARGET_FINGERPRINT "$PREVIEW_STATE")" = "$(target_fingerprint)" ] \
    || die 'the preview targeted a different bucket or distribution.'
  [ "$(state_value REFRESH_METADATA "$PREVIEW_STATE")" = "$REFRESH_METADATA" ] \
    || die 'the preview metadata-refresh mode does not match this deployment.'
  [ "$(state_value PUBLIC_FINGERPRINT "$PREVIEW_STATE")" = "$1" ] \
    || die 'public/ changed after the dry-run preview; preview again before deploying.'
}

prepare_force_upload_stage() {
  force_stage=''
  FORCE_UPLOAD_COUNT=0
  if [ "$REFRESH_METADATA" -eq 1 ]; then
    return 0
  fi

  current_manifest=$(mktemp "${TMPDIR:-/tmp}/hugo-deploy-current.XXXXXX")
  changed_files=$(mktemp "${TMPDIR:-/tmp}/hugo-deploy-changed.XXXXXX")
  write_public_manifest "$current_manifest"
  awk -F '\t' '
    NR == FNR { original[$2] = $1; next }
    !($2 in original) || original[$2] != $1 { print $2 }
  ' "$BUILD_MANIFEST" "$current_manifest" > "$changed_files"

  if [ -s "$changed_files" ]; then
    mkdir -p "$STATE_DIR"
    force_stage=$(mktemp -d "$STATE_DIR/force-upload.XXXXXX")
    while IFS= read -r relative; do
      [ -n "$relative" ] || continue
      [ -f "public/$relative" ] || continue
      mkdir -p "$force_stage/$(dirname "$relative")"
      ln "public/$relative" "$force_stage/$relative" \
        || die "could not stage changed output for forced upload: $relative"
      FORCE_UPLOAD_COUNT=$((FORCE_UPLOAD_COUNT + 1))
    done < "$changed_files"
  fi

  rm -f "$current_manifest" "$changed_files"
}

run_transfer() {
  printf '+ aws'
  for arg in "$@"; do printf ' %q' "$arg"; done
  printf '\n'
  "$AWS_BIN" "$@" | tee -a "$transfer_log"
}

run_transfer_with_mode() {
  if [ "$DRY_RUN" -eq 1 ]; then
    run_transfer "$@" --dryrun
  else
    run_transfer "$@"
  fi
}

run_cache_class_transfers() {
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

  if [ "$REFRESH_METADATA" -eq 1 ]; then
    printf 'Re-uploading every object to apply Cache-Control metadata.\n'
    run_transfer_with_mode s3 cp public/ "$destination" --recursive --no-progress \
      --cache-control "$IMMUTABLE_CACHE" "${immutable_filters[@]}"
    run_transfer_with_mode s3 cp public/ "$destination" --recursive --no-progress \
      --cache-control "$MUTABLE_CACHE" "${mutable_filters[@]}"
    run_transfer_with_mode s3 cp public/ "$destination" --recursive --no-progress \
      --cache-control "$OTHER_CACHE" "${other_filters[@]}"
  elif [ "$FORCE_UPLOAD_COUNT" -gt 0 ]; then
    printf 'Forcing upload of %s file(s) whose bytes changed after the Hugo build.\n' "$FORCE_UPLOAD_COUNT"
    run_transfer_with_mode s3 cp "$force_stage/" "$destination" --recursive --no-progress \
      --cache-control "$IMMUTABLE_CACHE" "${immutable_filters[@]}"
    run_transfer_with_mode s3 cp "$force_stage/" "$destination" --recursive --no-progress \
      --cache-control "$MUTABLE_CACHE" "${mutable_filters[@]}"
    run_transfer_with_mode s3 cp "$force_stage/" "$destination" --recursive --no-progress \
      --cache-control "$OTHER_CACHE" "${other_filters[@]}"
  fi

  sync_flags=(--delete --no-progress)
  run_transfer_with_mode s3 sync public/ "$destination" "${sync_flags[@]}" \
    --cache-control "$IMMUTABLE_CACHE" "${immutable_filters[@]}"
  run_transfer_with_mode s3 sync public/ "$destination" "${sync_flags[@]}" \
    --cache-control "$MUTABLE_CACHE" "${mutable_filters[@]}"
  run_transfer_with_mode s3 sync public/ "$destination" "${sync_flags[@]}" \
    --cache-control "$OTHER_CACHE" "${other_filters[@]}"
}

transfer_actions() {
  while IFS= read -r line; do
    line=${line#'(dryrun) '}
    case "$line" in
      *"upload: "*" to s3://$BUCKET/"*) printf 'upload\t%s\n' "${line##* to s3://$BUCKET/}" ;;
      *"copy: "*" to s3://$BUCKET/"*) printf 'upload\t%s\n' "${line##* to s3://$BUCKET/}" ;;
      *"delete: s3://$BUCKET/"*) printf 'delete\t%s\n' "${line##*delete: s3://$BUCKET/}" ;;
    esac
  done < "$transfer_log" | sed '/^$/d' | LC_ALL=C sort -u
}

changed_keys() {
  transfer_actions | cut -f 2-
}

invalidation_paths() {
  if [ "$REFRESH_METADATA" -eq 1 ]; then
    printf '/*\n'
    return
  fi

  changed_keys | while IFS= read -r key; do
    case "$key" in
      *.html|*.xml|robots.txt)
        encoded_key=${key// /%20}
        printf '/%s\n' "$encoded_key"
        if [ "$key" = index.html ]; then
          printf '/\n'
        elif [ "${key%/index.html}" != "$key" ]; then
          viewer="/${key%index.html}"
          viewer=${viewer// /%20}
          printf '%s\n' "$viewer"
          printf '%s\n' "${viewer%/}"
        fi
        ;;
    esac
  done | sed '/^$/d' | LC_ALL=C sort -u
}

transfer_plan_fingerprint() {
  {
    printf 'refresh=%s\n' "$REFRESH_METADATA"
    transfer_actions
    invalidation_paths
  } | hash_stream
}

send_invalidations() {
  paths=$1
  [ -n "$paths" ] || { printf 'No mutable paths changed; no invalidation is needed.\n'; return; }

  printf 'Paths to invalidate (%s):\n%s\n' "$DIST_ID" "$paths"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'DRY RUN: no CloudFront invalidation was created.\n'
    return
  fi

  max=30
  index=0
  batch=''
  caller_base="deploy-$(date +%s)"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    batch="${batch}${item}"$'\n'
    index=$((index + 1))
    if [ $((index % max)) -eq 0 ]; then
      create_invalidation "$batch" "$caller_base-$index"
      batch=''
    fi
  done <<EOF
$paths
EOF
  [ -z "$batch" ] || create_invalidation "$batch" "$caller_base-final"
}

create_invalidation() {
  batch=$1
  caller=$2
  items=$(printf '%s' "$batch" | awk 'NF { printf "\"%s\",", $0 }' | sed 's/,$//')
  count=$(printf '%s' "$batch" | sed '/^$/d' | wc -l | tr -d ' ')
  body='{"Paths":{"Quantity":'"$count"',"Items":['"$items"']},"CallerReference":"'"$caller"'"}'
  "$AWS_BIN" cloudfront create-invalidation \
    --distribution-id "$DIST_ID" \
    --invalidation-batch "$body" >/dev/null
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-only) BUILD_ONLY=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --refresh-metadata) REFRESH_METADATA=1 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

if [ "$BUILD_ONLY" -eq 1 ]; then
  [ "$SKIP_BUILD" -eq 0 ] || die '--build-only and --skip-build are mutually exclusive.'
  [ "$DRY_RUN" -eq 0 ] || die '--dry-run is not used with --build-only.'
  [ "$REFRESH_METADATA" -eq 0 ] || die '--refresh-metadata is not used with --build-only.'
  printf 'Building a clean production site with Hugo...\n'
  "$HUGO_BIN" --minify --gc --cleanDestinationDir --panicOnWarning
  assert_public_is_deployable
  source_hash=$(source_fingerprint)
  public_hash=$(record_build_manifest)
  write_build_state "$source_hash" "$public_hash"
  printf 'Build recorded: %s\n' "$public_hash"
  printf 'Next: open -a ImageOptim public/ and wait for optimisation to finish.\n'
  printf 'Then: ./deploy.sh --skip-build --dry-run\n'
  exit 0
fi

[ "$SKIP_BUILD" -eq 1 ] || die 'deployment requires --skip-build so Hugo cannot overwrite optimised output. Run --build-only first.'
validate_recorded_build

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

before_hash=$(public_fingerprint)
if [ "$DRY_RUN" -eq 0 ]; then
  validate_preview_state "$before_hash"
fi

prepare_force_upload_stage
transfer_log=$(mktemp "${TMPDIR:-/tmp}/hugo-deploy-transfer.XXXXXX")
cleanup() {
  rm -f -- "${transfer_log:-}"
  if [ -n "${force_stage:-}" ]; then
    case "$force_stage" in
      "$STATE_DIR"/force-upload.*) rm -rf -- "$force_stage" ;;
    esac
  fi
}
trap cleanup EXIT HUP INT TERM
: > "$transfer_log"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'DRY RUN: previewing the recorded public/ output.\n'
  run_cache_class_transfers

  after_hash=$(public_fingerprint)
  [ "$after_hash" = "$before_hash" ] || die 'public/ changed during the operation; preview was discarded.'
  plan_hash=$(transfer_plan_fingerprint)
  paths=$(invalidation_paths)
  send_invalidations "$paths"
  write_preview_state "$after_hash" "$plan_hash"
  printf 'DRY RUN complete. No objects or CloudFront configuration were changed.\n'
  printf 'Preview recorded for public/ hash: %s\n' "$after_hash"
else
  printf 'Rechecking the remote transfer plan immediately before deployment...\n'
  DRY_RUN=1
  run_cache_class_transfers
  preflight_hash=$(public_fingerprint)
  [ "$preflight_hash" = "$before_hash" ] || die 'public/ changed during the pre-deployment check.'
  current_plan=$(transfer_plan_fingerprint)
  expected_plan=$(state_value TRANSFER_PLAN_FINGERPRINT "$PREVIEW_STATE")
  [ -n "$expected_plan" ] || die 'the recorded preview has no remote transfer plan; run the dry run again.'
  [ "$current_plan" = "$expected_plan" ] \
    || die 'the S3 transfer plan changed after the reviewed dry run; preview again before deploying.'

  : > "$transfer_log"
  DRY_RUN=0
  printf 'Deploying the exact public/ output recorded by the dry run.\n'
  run_cache_class_transfers
  after_hash=$(public_fingerprint)
  [ "$after_hash" = "$before_hash" ] || die 'public/ changed during deployment; invalidation was stopped.'
  paths=$(invalidation_paths)
  send_invalidations "$paths"
  rm -f "$PREVIEW_STATE"
  printf 'Deploy complete. Cache metadata applied to transferred objects and invalidations sent.\n'
fi
