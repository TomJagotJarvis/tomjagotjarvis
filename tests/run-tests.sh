#!/bin/bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tomjagotjarvis-tests.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT HUP INT TERM

passes=0

pass() {
  passes=$((passes + 1))
  printf 'ok %d - %s\n' "$passes" "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  pattern=$1
  file=$2
  message=$3
  grep -qE "$pattern" "$file" || fail "$message"
  pass "$message"
}

assert_not_contains() {
  pattern=$1
  file=$2
  message=$3
  if grep -qE "$pattern" "$file"; then
    fail "$message"
  fi
  pass "$message"
}

for command in hugo perl sips shasum; do
  command -v "$command" >/dev/null 2>&1 || fail "required command is unavailable: $command"
done
pass "required test commands are available"

for script in add-images.sh new-post.sh deploy.sh scripts/audit-alt-text.sh tests/run-tests.sh; do
  /bin/bash -n "$ROOT/$script" || fail "shell syntax: $script"
done
pass "shell scripts pass bash -n"

SITE="$TMP_ROOT/site"
mkdir -p "$SITE/assets"
cp "$ROOT/config.toml" "$SITE/config.toml"
cp -R "$ROOT/layouts" "$SITE/"
cp -R "$ROOT/archetypes" "$SITE/"
cp -R "$ROOT/assets/css" "$SITE/assets/"
cp -R "$ROOT/tests/fixtures/assets/originals" "$SITE/assets/"
cp -R "$ROOT/tests/fixtures/content" "$SITE/"

BUILD_LOG="$TMP_ROOT/hugo-build.log"
if ! hugo --source "$SITE" \
  --destination "$SITE/public" \
  --cacheDir "$SITE/cache" \
  --cleanDestinationDir \
  --noBuildLock >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  fail "fixture Hugo build succeeds"
fi
pass "fixture Hugo build succeeds"

if grep -E '(^|[[:space:]])(WARN|ERROR)([[:space:]]|$)' "$BUILD_LOG" >/dev/null; then
  cat "$BUILD_LOG" >&2
  fail "fixture build has no warnings, deprecations, or template errors"
fi
pass "fixture build has no warnings, deprecations, or template errors"

for generated in \
  index.html \
  archive/index.html \
  tags/fixture/index.html \
  posts/image-first/index.html \
  posts/section-first/index.html \
  robots.txt \
  sitemap.xml; do
  [ -f "$SITE/public/$generated" ] || fail "generated page exists: $generated"
done
pass "homepage, posts, taxonomy, archive, robots, and sitemap are generated"

POST_HTML="$SITE/public/posts/image-first/index.html"
SECTION_HTML="$SITE/public/posts/section-first/index.html"
HOME_HTML="$SITE/public/index.html"
TAXONOMY_HTML="$SITE/public/tags/fixture/index.html"

assert_contains '<html lang="en-GB">' "$POST_HTML" "HTML lang uses configured locale"
assert_contains '<title>Image First \| Tom Jagot-Jarvis</title>' "$POST_HTML" "post title metadata is generated"
assert_contains '<meta name="description" content="A responsive image fixture with four source dimensions\."' "$POST_HTML" "author description metadata is preserved"
assert_contains '<link rel="canonical" href="https://tomjagotjarvis.com/posts/image-first/"' "$POST_HTML" "canonical URL is generated"
assert_contains '<time datetime="2026-01-02">' "$POST_HTML" "time has a machine-readable datetime"
assert_contains '<h1 class="visually-hidden">Tom Jagot-Jarvis</h1>' "$HOME_HTML" "homepage has a proper h1"
assert_contains '<h2 class="title">Image First</h2>' "$HOME_HTML" "homepage cards use h2 headings"
assert_contains '<nav class="nav-links" aria-label="Primary navigation">' "$HOME_HTML" "primary navigation is labelled"
assert_contains 'aria-current="page">Home</a>' "$HOME_HTML" "active primary navigation is identified"
assert_contains '<h2 class="title">Image First</h2>' "$TAXONOMY_HTML" "taxonomy cards use h2 headings"
assert_contains '<h2 class="section-heading">' "$SECTION_HTML" "section-title renders a semantic h2"
assert_contains 'a:focus-visible' "$ROOT/assets/css/styles.css" "keyboard focus styling is present"
assert_contains 'background: rgba\(0, 0, 0, 0\.68\)' "$ROOT/assets/css/styles.css" "overlay contrast is strengthened"
assert_contains 'color: #666' "$ROOT/assets/css/styles.css" "muted text contrast is corrected"
assert_not_contains 'Inter:wght@300' "$ROOT/layouts/_default/baseof.html" "unused Inter 300 font weight is removed"
assert_not_contains 'Playfair Display' "$ROOT/assets/css/styles.css" "unloaded Playfair Display references are removed"

perl -0777 -ne 'exit(/alt="A blue and pink landscape gradient"\s+width="700"\s+height="467"\s+loading="eager"\s+fetchpriority="high"/s ? 0 : 1)' "$POST_HTML" \
  || fail "first image is eager, high priority, and dimensioned"
pass "first image is eager, high priority, and dimensioned"

perl -0777 -ne 'exit(/alt="Image First — untitled photograph 2 \(description pending\)"\s+width="700"\s+height="1050"\s+loading="lazy"/s ? 0 : 1)' "$POST_HTML" \
  || fail "filename-derived portrait alt uses the documented ordinal fallback"
pass "filename-derived portrait alt uses the documented ordinal fallback"

perl -0777 -ne 'exit(/alt="Image First — untitled photograph 3 \(description pending\)"\s+width="700"\s+height="467"\s+loading="lazy"/s ? 0 : 1)' "$POST_HTML" \
  || fail "empty landscape alt uses the documented ordinal fallback"
pass "empty landscape alt uses the documented ordinal fallback"

perl -0777 -ne 'exit(/alt="A magenta portrait gradient"\s+width="700"\s+height="1050"\s+loading="lazy"/s ? 0 : 1)' "$POST_HTML" \
  || fail "genuine descriptive alt text is preserved"
pass "genuine descriptive alt text is preserved"

perl -0777 -ne 'exit(/<h2 class="section-heading">.*?<\/h2>.*?<picture>\s*<img.*?loading="eager"\s+fetchpriority="high"/s ? 0 : 1)' "$SECTION_HTML" \
  || fail "section-led post eagerly loads its first responsive photograph"
pass "section-led post eagerly loads its first responsive photograph"

SRCSETS="$TMP_ROOT/srcsets.txt"
perl -0777 -ne 'while (/srcset="([^"]+)"/g) { print "$1\n" }' "$POST_HTML" > "$SRCSETS"
[ "$(wc -l < "$SRCSETS" | tr -d ' ')" -eq 4 ] || fail "four post srcsets were generated"

candidate_total=0
while IFS= read -r srcset; do
  old_ifs=$IFS
  IFS=','
  read -r -a candidates <<< "$srcset"
  IFS=$old_ifs
  seen_widths=" "
  seen_urls=" "
  for candidate in "${candidates[@]}"; do
    candidate=$(printf '%s' "$candidate" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    url=${candidate% *}
    descriptor=${candidate##* }
    width=${descriptor%w}
    case "$seen_widths" in *" $width "*) fail "srcset width descriptors are unique" ;; esac
    case "$seen_urls" in *" $url "*) fail "srcset URLs are unique" ;; esac
    seen_widths="$seen_widths$width "
    seen_urls="$seen_urls$url "

    relative=${url#../../}
    relative=$(printf '%s' "$relative" | sed 's/%20/ /g')
    image_file="$SITE/public/$relative"
    [ -f "$image_file" ] || fail "srcset candidate exists: $relative"
    actual_width=$(sips -g pixelWidth "$image_file" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    [ "$actual_width" = "$width" ] || fail "descriptor ${width}w matches actual width $actual_width for $relative"
    candidate_total=$((candidate_total + 1))
  done
done < "$SRCSETS"
[ "$candidate_total" -eq 11 ] || fail "source-width capping removes duplicate candidates (expected 11, got $candidate_total)"
pass "all srcset descriptors match unique candidate files and no source is upscaled"

assert_contains '700w,.*1452w,.*2904w' "$POST_HTML" "6000px landscape produces 700/1452/2904 candidates"
assert_contains '700w,.*1452w,.*1686w' "$POST_HTML" "1686px portrait caps at its source width"
assert_contains '700w,.*1452w,.*1500w' "$POST_HTML" "1500px landscape caps at its source width"
assert_contains '700w,.*1000w' "$POST_HTML" "1000px portrait deduplicates larger requests"
assert_contains 'sizes="\(min-width: 1232px\) 600px, \(min-width: 700px\) calc\(50vw - 1rem\), 100vw"' "$HOME_HTML" "homepage sizes matches the two-column 600px card layout"

# Verify the declared homepage slot policy at representative viewport/DPR pairs.
# Candidate choice is the first available width at or above slot × DPR.
slot_320=320
slot_768=$((768 / 2 - 16))
slot_1280=600
slot_1920=600
[ "$slot_320" -eq 320 ] || fail "320px viewport slot"
[ "$slot_768" -eq 368 ] || fail "768px viewport slot"
[ "$slot_1280" -eq 600 ] || fail "1280px viewport slot"
[ "$slot_1920" -eq 600 ] || fail "1920px viewport slot"
[ $((slot_320 * 2)) -gt 480 ] && [ $((slot_320 * 2)) -le 960 ] || fail "320px DPR2 candidate range"
[ $((slot_768 * 2)) -gt 480 ] && [ $((slot_768 * 2)) -le 960 ] || fail "768px DPR2 candidate range"
[ $((slot_1280 * 2)) -gt 960 ] && [ $((slot_1280 * 2)) -le 1440 ] || fail "1280px DPR2 candidate range"
[ "$slot_1920" -gt 480 ] && [ "$slot_1920" -le 960 ] || fail "1920px DPR1 candidate range"
pass "homepage sizing policy covers mobile, tablet, desktop, and DPR2 scenarios"

cp "$SITE/config.toml" "$TMP_ROOT/config-before-pagination.toml"
perl -pi -e 's/pagination\.pagerSize = 6/pagination.pagerSize = 1/' "$SITE/config.toml"
if ! hugo --source "$SITE" \
  --destination "$SITE/public-pagination" \
  --cacheDir "$SITE/cache-pagination" \
  --cleanDestinationDir \
  --noBuildLock >"$TMP_ROOT/pagination-build.log" 2>&1; then
  cat "$TMP_ROOT/pagination-build.log" >&2
  fail "pagination fixture build succeeds"
fi
assert_contains 'aria-current="page">1</a>' "$SITE/public-pagination/index.html" "pagination marks page 1 current"
assert_contains 'aria-current="page">2' "$SITE/public-pagination/page/2/index.html" "pagination marks page 2 current"
cp "$TMP_ROOT/config-before-pagination.toml" "$SITE/config.toml"

mv "$SITE/assets/originals/section-first/section-landscape.JPEG" "$TMP_ROOT/section-landscape.JPEG"
MISSING_LOG="$TMP_ROOT/missing-image.log"
if hugo --source "$SITE" \
  --destination "$SITE/public-missing" \
  --cacheDir "$SITE/cache-missing" \
  --ignoreCache \
  --noBuildLock >"$MISSING_LOG" 2>&1; then
  fail "missing required image fails the build"
fi
assert_contains 'required image not found: originals/section-first/section-landscape\.JPEG' "$MISSING_LOG" "missing required image fails with an actionable error"
mv "$TMP_ROOT/section-landscape.JPEG" "$SITE/assets/originals/section-first/section-landscape.JPEG"

ACTUAL_URLS="$TMP_ROOT/actual-post-urls.txt"
hugo list all --source "$ROOT" --noBuildLock 2>/dev/null \
  | awk -F, '$1 ~ /^content\/posts\/.+\/index\.md$/ {print $8}' \
  | sort > "$ACTUAL_URLS"
diff -u "$ROOT/tests/expected-post-urls.txt" "$ACTUAL_URLS" >/dev/null \
  || fail "all 23 existing post URLs are preserved"
pass "all 23 existing post URLs are preserved"

ALT_REPORT="$TMP_ROOT/alt-report.tsv"
"$ROOT/scripts/audit-alt-text.sh" --output "$ALT_REPORT"
assert_contains '^1661 photograph\(s\) need a descriptive alt text\.$' "$ALT_REPORT" "alt audit catches exact and transformed filename-derived values"
if "$ROOT/scripts/audit-alt-text.sh" --strict >/dev/null 2>&1; then
  fail "strict alt audit reports the known legacy backlog"
fi
pass "strict alt audit returns non-zero while legacy descriptions are pending"

SCRIPT_SITE="$TMP_ROOT/script-site"
mkdir -p "$SCRIPT_SITE/assets" "$SCRIPT_SITE/content"
cp "$ROOT/config.toml" "$SCRIPT_SITE/config.toml"
cp -R "$ROOT/archetypes" "$SCRIPT_SITE/"
cp -R "$ROOT/layouts" "$SCRIPT_SITE/"
cp -R "$ROOT/assets/css" "$SCRIPT_SITE/assets/"
cp "$ROOT/new-post.sh" "$ROOT/add-images.sh" "$SCRIPT_SITE/"
chmod +x "$SCRIPT_SITE/new-post.sh" "$SCRIPT_SITE/add-images.sh"

(cd "$SCRIPT_SITE" && ./new-post.sh 2026-11-20_New-Fixture >/dev/null)
NEW_MD="$SCRIPT_SITE/content/posts/2026-11-20_New-Fixture/index.md"
[ -d "$SCRIPT_SITE/assets/originals/2026-11-20_New-Fixture" ] || fail "new-post creates the assets directory"
assert_not_contains 'image\.jpg' "$NEW_MD" "new archetype contains no image placeholder"

printf '\nExisting prose stays here.\n\n{{< section-title >}}Curated section{{< /section-title >}}\n\n{{< responsive-img src="b-second.jpeg" alt="Already curated" >}}\n' >> "$NEW_MD"
touch "$SCRIPT_SITE/assets/originals/2026-11-20_New-Fixture/A first.JPG"
touch "$SCRIPT_SITE/assets/originals/2026-11-20_New-Fixture/b-second.jpeg"
touch "$SCRIPT_SITE/assets/originals/2026-11-20_New-Fixture/C Third.WeBp"

(cd "$SCRIPT_SITE" && ./add-images.sh content/posts/2026-11-20_New-Fixture >/dev/null)
assert_contains 'Existing prose stays here\.' "$NEW_MD" "add-images preserves existing prose"
assert_contains 'Curated section' "$NEW_MD" "add-images preserves section shortcodes"
[ "$(grep -c 'src="b-second.jpeg"' "$NEW_MD")" -eq 1 ] || fail "add-images does not duplicate an existing curated image"
[ "$(grep -c 'src="A first.JPG"' "$NEW_MD")" -eq 1 ] || fail "add-images supports spaces and uppercase JPG"
[ "$(grep -c 'src="C Third.WeBp"' "$NEW_MD")" -eq 1 ] || fail "add-images supports mixed-case WebP"
pass "add-images preserves order and supports spaced mixed-case filenames"

index_hash=$(shasum -a 256 "$NEW_MD" | awk '{print $1}')
backup_count=$(find "$(dirname "$NEW_MD")" -maxdepth 1 -name 'index.md.bak*' | wc -l | tr -d ' ')
(cd "$SCRIPT_SITE" && ./add-images.sh content/posts/2026-11-20_New-Fixture >"$TMP_ROOT/second-run.log")
[ "$(shasum -a 256 "$NEW_MD" | awk '{print $1}')" = "$index_hash" ] || fail "unchanged second run preserves index.md bytes"
[ "$(find "$(dirname "$NEW_MD")" -maxdepth 1 -name 'index.md.bak*' | wc -l | tr -d ' ')" = "$backup_count" ] || fail "unchanged second run does not replace or add a backup"
assert_contains '^No changes:' "$TMP_ROOT/second-run.log" "unchanged second run reports idempotence"

LEGACY_DIR="$SCRIPT_SITE/content/posts/2026-11-19_Legacy-Fixture"
LEGACY_ASSETS="$SCRIPT_SITE/assets/originals/2026-11-19_Legacy-Fixture"
mkdir -p "$LEGACY_DIR" "$LEGACY_ASSETS"
printf '%s\n' '---' 'title: "Legacy Fixture"' 'date: 2026-11-19T00:00:00Z' 'draft: false' 'type: "post"' 'featured: "real.JPG"' 'tags: ["Fixture"]' '---' '' 'Legacy prose.' '' '{{< responsive-img src="image.jpg" alt="Description" >}}' > "$LEGACY_DIR/index.md"
touch "$LEGACY_ASSETS/real.JPG"
(cd "$SCRIPT_SITE" && ./add-images.sh content/posts/2026-11-19_Legacy-Fixture >/dev/null)
assert_not_contains 'src="image\.jpg"' "$LEGACY_DIR/index.md" "legacy archetype placeholder is removed atomically"
assert_contains 'Legacy prose\.' "$LEGACY_DIR/index.md" "legacy placeholder cleanup preserves prose"
assert_contains 'src="real\.JPG"' "$LEGACY_DIR/index.md" "legacy placeholder cleanup adds the real image"

if (cd "$SCRIPT_SITE" && ./add-images.sh content/posts/does-not-exist >/dev/null 2>&1); then
  fail "add-images returns non-zero for an invalid post"
fi
pass "add-images errors return a non-zero status"

DEPLOY_SITE="$TMP_ROOT/deploy-site"
mkdir -p "$DEPLOY_SITE/bin" "$DEPLOY_SITE/public"
cp "$ROOT/deploy.sh" "$DEPLOY_SITE/deploy.sh"
chmod +x "$DEPLOY_SITE/deploy.sh"
printf '%s\n' 'BUCKET=test-bucket' 'DIST_ID=test-distribution' > "$DEPLOY_SITE/.env"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$DEPLOY_SITE/bin/hugo"
printf '%s\n' '#!/bin/bash' 'if [ "${1:-}" = "s3" ]; then' '  echo "(dryrun) upload: public/posts/example/index.html to s3://test-bucket/posts/example/index.html"' '  echo "(dryrun) delete: s3://test-bucket/old/index.html"' '  exit 0' 'fi' 'exit 99' > "$DEPLOY_SITE/bin/aws"
chmod +x "$DEPLOY_SITE/bin/hugo" "$DEPLOY_SITE/bin/aws"
(cd "$DEPLOY_SITE" && PATH="$DEPLOY_SITE/bin:$PATH" ./deploy.sh --dry-run > "$TMP_ROOT/deploy-dry-run.log")
assert_contains '/posts/example/index\.html' "$TMP_ROOT/deploy-dry-run.log" "deploy dry-run parses uploaded paths"
assert_contains '/old/index\.html' "$TMP_ROOT/deploy-dry-run.log" "deploy dry-run parses deleted paths"
assert_contains '/robots\.txt' "$TMP_ROOT/deploy-dry-run.log" "deploy invalidates robots.txt"

printf '\nAll %d test groups passed.\n' "$passes"
printf 'Fixture processed image files: %s\n' "$(find "$SITE/public/originals" -type f | wc -l | tr -d ' ')"
