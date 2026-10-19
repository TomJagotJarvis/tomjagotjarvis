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

# Check front matter is present (two --- lines)
if [ "$(grep -c '^---$' "$MD_FILE")" -lt 2 ]; then
  echo "❌ Front matter not properly formatted in $MD_FILE"
  exit 1
fi

# Backup index.md
cp "$MD_FILE" "$MD_FILE.bak"

# Match extensions case-insensitively (.jpg and .JPG)
shopt -s nullglob nocaseglob

# Append shortcodes for images not already in the post.
# Existing body text (section titles, captions, etc.) is preserved.
#
# alt is left empty on purpose: the shortcode falls back to
# "Photo from <post title>". Replace it with a real description of each photo.
added=0
for img in "$ASSET_DIR"/*.{jpg,jpeg,png,webp}; do
  [ -f "$img" ] || continue
  filename=$(basename "$img")
  if grep -qF "src=\"$filename\"" "$MD_FILE"; then
    continue
  fi
  printf '\n{{< responsive-img src="%s" alt="" >}}\n' "$filename" >> "$MD_FILE"
  added=$((added + 1))
done

echo "✅ Added $added image shortcode(s) to $MD_FILE. Backup: index.md.bak"
echo "   Remember to fill in alt=\"\" with a description of each photo."
