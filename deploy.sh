#!/bin/bash

set -e

# Load environment variables from .env
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
else
  echo "❌ .env file not found."
  exit 1
fi

# Use loaded values
echo "🟡 Syncing changes to S3 bucket: $BUCKET"

CHANGED=$(aws s3 sync public/ s3://$BUCKET --delete \
  --exact-timestamps \
  --only-show-errors \
  | grep "upload:" \
  | awk '{print $3}' \
  | sed 's|^public||')

if [ -z "$CHANGED" ]; then
  echo "✅ No changes detected. Skipping invalidation."
  exit 0
fi

echo "🟠 Files changed:"
echo "$CHANGED"

echo "⚙️ Creating CloudFront invalidation..."

JSON_PATHS=$(echo "$CHANGED" | awk '{print "\""$0"\""}' | paste -sd, -)
JSON_BODY="{\"Paths\":{\"Quantity\":$(echo "$CHANGED" | wc -l | tr -d ' '),\"Items\":[${JSON_PATHS}]},\"CallerReference\":\"deploy-$(date +%s)\"}"

aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --cli-input-json "$JSON_BODY"

echo "✅ Deploy and selective invalidation complete."
