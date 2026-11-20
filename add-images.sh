#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: $0 path/to/post-folder (for example: content/posts/2026-11-20_My-Post)" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$1" in
  /*) POST_DIR=$1 ;;
  *) POST_DIR="$PWD/$1" ;;
esac

MD_FILE="$POST_DIR/index.md"
SLUG=$(basename -- "$POST_DIR")
ASSET_DIR="$SCRIPT_DIR/assets/originals/$SLUG"

if [ ! -f "$MD_FILE" ]; then
  echo "Error: no index.md found in $POST_DIR" >&2
  exit 1
fi

if [ ! -d "$ASSET_DIR" ]; then
  echo "Error: no assets directory found at $ASSET_DIR" >&2
  exit 1
fi

if [ "$(grep -c '^---$' "$MD_FILE" || true)" -lt 2 ]; then
  echo "Error: front matter is not properly delimited in $MD_FILE" >&2
  exit 1
fi

PLACEHOLDER='{{< responsive-img src="image.jpg" alt="Description" >}}'
remove_placeholder=0
if grep -qxF "$PLACEHOLDER" "$MD_FILE"; then
  remove_placeholder=1
fi

LC_ALL=C
export LC_ALL
shopt -s nullglob
images=("$ASSET_DIR"/*)
new_images=()

for img in "${images[@]}"; do
  [ -f "$img" ] || continue
  filename=$(basename -- "$img")
  extension=$(printf '%s' "${filename##*.}" | tr '[:upper:]' '[:lower:]')
  case "$extension" in
    jpg|jpeg|png|webp) ;;
    *) continue ;;
  esac

  case "$filename" in
    *'"'*)
      echo "Error: image filenames cannot contain a double quote: $filename" >&2
      exit 1
      ;;
  esac

  if grep -qF "src=\"$filename\"" "$MD_FILE"; then
    continue
  fi
  new_images+=("$filename")
done

if [ "$remove_placeholder" -eq 0 ] && [ "${#new_images[@]}" -eq 0 ]; then
  echo "No changes: all supported images are already present in $MD_FILE"
  exit 0
fi

tmp_file=$(mktemp "$POST_DIR/.index.md.XXXXXX")
cleanup() {
  rm -f -- "$tmp_file"
}
trap cleanup EXIT HUP INT TERM

awk -v placeholder="$PLACEHOLDER" '$0 != placeholder { print }' "$MD_FILE" > "$tmp_file"

for filename in "${new_images[@]}"; do
  printf '\n{{< responsive-img src="%s" alt="" >}}\n' "$filename" >> "$tmp_file"
done

# Preserve the original file mode on GNU and BSD/macOS systems.
chmod --reference="$MD_FILE" "$tmp_file" 2>/dev/null || chmod "$(stat -f '%Lp' "$MD_FILE")" "$tmp_file"

backup="$MD_FILE.bak"
if [ -e "$backup" ]; then
  timestamp=$(date '+%Y%m%d-%H%M%S')
  backup="$MD_FILE.bak.$timestamp"
  suffix=1
  while [ -e "$backup" ]; do
    backup="$MD_FILE.bak.$timestamp.$suffix"
    suffix=$((suffix + 1))
  done
fi

cp -p -- "$MD_FILE" "$backup"
mv -f -- "$tmp_file" "$MD_FILE"
trap - EXIT HUP INT TERM

echo "Updated $MD_FILE"
echo "  Added ${#new_images[@]} image shortcode(s)"
if [ "$remove_placeholder" -eq 1 ]; then
  echo "  Removed the archetype image placeholder"
fi
echo "  Backup: $backup"
echo "Add real alt descriptions where alt=\"\" appears; run ./scripts/audit-alt-text.sh to review the backlog."
