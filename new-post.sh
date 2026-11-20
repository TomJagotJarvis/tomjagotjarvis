#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 YYYY-MM-DD_slug (for example: 2026-11-20_My-Post)" >&2
  exit 2
fi

SLUG=$1
case "$SLUG" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) ;;
  *)
    echo "Error: post name must begin YYYY-MM-DD_" >&2
    exit 2
    ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

POST_PATH="posts/$SLUG/index.md"
ASSETS_PATH="assets/originals/$SLUG"

if [ -e "content/$POST_PATH" ] || [ -e "$ASSETS_PATH" ]; then
  echo "Error: post or asset directory already exists for $SLUG" >&2
  exit 1
fi

hugo new "$POST_PATH"
mkdir -p -- "$ASSETS_PATH"

echo "Created post at content/$POST_PATH"
echo "Created assets directory at $ASSETS_PATH"
