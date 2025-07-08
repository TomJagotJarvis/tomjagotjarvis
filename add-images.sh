#!/bin/bash

# Usage check
if [ -z "$1" ]; then
  echo "❌ Usage: $0 path/to/post-folder (e.g., content/posts/my-first-post)"
  exit 1
fi

POST_DIR="$1"
MD_FILE="$POST_DIR/index.md"

# Validate index.md presence
if [ ! -f "$MD_FILE" ]; then
  echo "❌ No index.md found in $POST_DIR"
  exit 1
fi

# Extract the slug from the post directory
SLUG=$(basename "$POST_DIR")

# Define the assets directory for this post
ASSET_DIR="assets/originals/$SLUG"

if [ ! -d "$ASSET_DIR" ]; then
  echo "❌ No assets directory found at $ASSET_DIR"
  exit 1
fi

# Backup index.md
cp "$MD_FILE" "$MD_FILE.bak"

# Find where front matter ends (after 2nd ---)
HEADER_END_LINE=$(awk '/^---$/{c++} c==2 {print NR; exit}' "$MD_FILE")
if [ -z "$HEADER_END_LINE" ]; then
  echo "❌ Front matter not properly formatted in $MD_FILE"
  exit 1
fi

# Extract front matter
head -n "$HEADER_END_LINE" "$MD_FILE" > "$MD_FILE.tmp"
echo "" >> "$MD_FILE.tmp"

# Append responsive-img shortcodes for each image in the assets directory
for img in "$ASSET_DIR"/*.{jpg,jpeg,png,webp}; do
  [ -f "$img" ] || continue
  filename=$(basename "$img")
  alt_text=$(echo "$filename" | sed -E 's/\.[^.]+$//' | tr '-' ' ' | sed -E 's/\b(.)/\u\1/g')
  echo "{{< responsive-img src=\"$filename\" alt=\"$alt_text\" >}}" >> "$MD_FILE.tmp"
  echo "" >> "$MD_FILE.tmp"
done

# Replace the index.md file
mv "$MD_FILE.tmp" "$MD_FILE"

echo "✅ Updated $MD_FILE with responsive image shortcodes. Backup: index.md.bak"
