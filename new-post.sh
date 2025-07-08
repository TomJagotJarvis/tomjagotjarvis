#!/bin/bash

# Usage: ./new-post.sh YYYY-MM-DD_slug (e.g. 2023-01-01_st_lucia)

if [ -z "$1" ]; then
  echo "❌ Usage: $0 YYYY-MM-DD_slug"
  exit 1
fi

SLUG="$1"

# Create the new post
POST_PATH="posts/$SLUG/index.md"
hugo new "$POST_PATH"

# Create corresponding image folder in assets
ASSETS_PATH="assets/originals/$SLUG"
mkdir -p "$ASSETS_PATH"

echo "✅ Created post at content/$POST_PATH"
echo "✅ Created assets directory at $ASSETS_PATH"
