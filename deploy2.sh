#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# --- Load environment variables from .env safely ---
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
else
  echo "❌ .env file not found."
  exit 1
fi

# --- Required vars guardrails ---
: "${BUCKET:?❌ BUCKET not set in .env}"
: "${DIST_ID:?❌ DIST_ID not set in .env}"

# 1) Build the site (remove if you prefer to build separately)
echo "🏗️  Building site with Hugo…"
hugo --minify

echo "🟡 Syncing changes to S3 bucket: $BUCKET"

# 2) Run sync and capture output (don't use --only-show-errors)
SYNC_OUTPUT=$(aws s3 sync public/ "s3://$BUCKET" --delete --exact-timestamps --no-progress)

# 3) Parse changed paths (uploads & deletes)
#    For uploads: take the *source* path (public/...), strip "public"
#    For deletes: take the s3://... path, strip "s3://$BUCKET"
UPLOADS=$(echo "$SYNC_OUTPUT" | awk '/^upload:/ {print $2}' | sed 's|^public||')
DELETES=$(echo "$SYNC_OUTPUT" | awk '/^delete:/ {print $2}' | sed "s|^s3://$BUCKET||")

# 4) Combine, normalize to a single leading slash, de-dupe
CHANGED=$(printf "%s\n%s\n" "$UPLOADS" "$DELETES" \
  | sed '/^$/d' \
  | sed -E 's|^/*|/|' \
  | sed -E 's|/+|/|g' \
  | sed '/^\/$/d' \
  | sort -u)

if [ -z "${CHANGED:-}" ]; then
  echo "✅ No changes detected. Skipping invalidation."
  exit 0
fi

echo "🟠 Files changed:"
echo "$CHANGED"

echo "⚙️ Creating CloudFront invalidation…"

# 5) Create CloudFront invalidations in batches (limit 30 paths per request)
MAX=30
CALLER_BASE="deploy-$(date +%s)"

send_invalidation_batch () {
  local batch_lines="$1"
  local caller="$2"

  # Build JSON items list and count
  local items count json_body
  items=$(printf "%s" "$batch_lines" | awk 'NF{printf "\"%s\",", $0}' | sed 's/,$//')
  count=$(printf "%s" "$batch_lines" | sed '/^$/d' | wc -l | tr -d ' ')

  # IMPORTANT: --invalidation-batch takes the *inner* object (no outer "InvalidationBatch")
  json_body='{"Paths":{"Quantity":'"$count"',"Items":['"$items"']}, "CallerReference":"'"$caller"'"}'

  aws cloudfront create-invalidation \
    --distribution-id "$DIST_ID" \
    --invalidation-batch "$json_body"
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
done <<< "$CHANGED"

# Flush remainder
if [ -n "$batch_lines" ]; then
  send_invalidation_batch "$batch_lines" "${CALLER_BASE}-final"
  sleep 1
fi

echo "✅ Deploy and selective invalidation complete."
