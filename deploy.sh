#!/bin/bash
# deploy2.sh (minimal invalidations + dry-run)
set -euo pipefail
export AWS_PAGER=""

# --- CLI flags ---------------------------------------------------------------
DRYRUN=0
while [[ "${1:-}" =~ ^- ]]; do
  case "$1" in
    -n|--dry-run) DRYRUN=1 ;;
    -h|--help)
      cat <<'HELP'
Usage: ./deploy2.sh [--dry-run]

--dry-run, -n  Build and show what would sync/invalidate, but do not upload or invalidate.
HELP
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
  shift || true
done

# --- Load env (.env must define BUCKET and DIST_ID) --------------------------
if [ -f .env ]; then
  set -a; . ./.env; set +a
else
  echo "❌ .env file not found."; exit 1
fi
: "${BUCKET:?❌ BUCKET not set in .env}"
: "${DIST_ID:?❌ DIST_ID not set in .env}"

# --- Build -------------------------------------------------------------------
echo "🏗️  Building site with Hugo…"
hugo --minify --gc --cleanDestinationDir

# --- Sync to S3 (capture output either real or dry) --------------------------
SYNC_FLAGS=(--delete --exact-timestamps --no-progress)
if (( DRYRUN )); then
  echo "🔎 DRY RUN: previewing sync to s3://$BUCKET …"
  SYNC_FLAGS+=(--dryrun)
else
  echo "🟡 Syncing changes to s3://$BUCKET …"
fi

SYNC_OUTPUT="$(aws s3 sync public/ "s3://$BUCKET" "${SYNC_FLAGS[@]}" || true)"

# --- Parse changed paths from sync output ------------------------------------
UPLOADS=$(echo "$SYNC_OUTPUT" | awk '/^upload:/ {print $2}' | sed 's|^public||')
DELETES=$(echo "$SYNC_OUTPUT" | awk '/^delete:/ {print $2}' | sed "s|^s3://$BUCKET||")

CHANGED=$(
  printf "%s\n%s\n" "$UPLOADS" "$DELETES" \
  | sed '/^$/d' \
  | sed -E 's|^/*|/|' | sed -E 's|/+|/|g' \
  | sed '/^\/$/d' \
  | sort -u
)

# Keep only HTML/XML (pages), not images/assets
CHANGED_HTML_XML=$(echo "$CHANGED" | grep -Ei '\.(html|xml)$' || true)

# Always-invalidate set (kept tiny)
FIXED=(
  "/"
  "/index.html"
  "/archive/index.html"
  "/sitemap.xml"
  "/index.xml"
)

# OPTIONAL: add targeted paths here when you change non-HTML assets.
# For example, if you edit your main CSS and keep the same filename:
# EXTRA+=( "/css/styles.css" )
EXTRA=()

# Merge + dedupe
ALL_PATHS=$(
  { printf "%s\n" "${FIXED[@]}"; printf "%s\n" "${EXTRA[@]:-}"; echo "$CHANGED_HTML_XML"; } \
  | sed '/^$/d' | sort -u
)

if [ -z "$ALL_PATHS" ]; then
  echo "✅ No HTML/XML changes detected."
  (( DRYRUN )) && echo "🧪 DRY RUN: nothing would be invalidated."
  exit 0
fi

echo "🟠 Paths to invalidate (${DIST_ID}):"
echo "$ALL_PATHS"

# --- Send invalidations (or preview in dry run) ------------------------------
MAX=30
CALLER_BASE="deploy-$(date +%s)"

send_invalidation_batch () {
  local batch_lines="$1"
  local caller="$2"
  local items count json_body
  items=$(printf "%s" "$batch_lines" | awk 'NF{printf "\"%s\",", $0}' | sed 's/,$//')
  count=$(printf "%s" "$batch_lines" | sed '/^$/d' | wc -l | tr -d ' ')
  json_body='{"Paths":{"Quantity":'"$count"',"Items":['"$items"']}, "CallerReference":"'"$caller"'"}'

  if (( DRYRUN )); then
    echo "🧪 DRY RUN: would create invalidation with $count path(s)."
    echo "$batch_lines"
  else
    aws cloudfront create-invalidation \
      --distribution-id "$DIST_ID" \
      --invalidation-batch "$json_body" >/dev/null
  fi
}

i=0
batch_lines=""
while IFS= read -r line; do
  batch_lines+="$line"$'\n'
  i=$((i+1))
  if (( i % MAX == 0 )); then
    send_invalidation_batch "$batch_lines" "${CALLER_BASE}-${i}"
    batch_lines=""
    sleep 1
  fi
done <<< "$ALL_PATHS"
if [ -n "$batch_lines" ]; then
  send_invalidation_batch "$batch_lines" "${CALLER_BASE}-final"
fi

if (( DRYRUN )); then
  echo "✅ DRY RUN complete. No uploads or invalidations were performed."
else
  echo "✅ Deploy complete. Targeted invalidations sent."
fi