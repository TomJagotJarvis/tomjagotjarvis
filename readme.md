# Tom Jagot-Jarvis photography website

This is a Hugo static photography site deployed to Amazon S3 behind CloudFront.
Posts are photo stories with responsive image variants generated from the source
JPEGs in `assets/originals/`.

## Requirements

- Hugo Extended. Phase 1 was tested with `hugo v0.167.0+extended+withdeploy`.
- macOS Bash 3.2 or newer for the repository scripts.
- AWS CLI only for deployment.

Check the installed version before building:

```bash
hugo version
```

## Create a post

From the repository root, use a name beginning with the publication date:

```bash
./new-post.sh 2026-11-20_My-Post
```

This creates:

- `content/posts/2026-11-20_My-Post/index.md`
- `assets/originals/2026-11-20_My-Post/`

Edit the front matter, set `featured` to a real filename, replace the starter
prose, and add tags.

## Add photographs

Copy photographs into the matching `assets/originals/<post>/` directory, then
run:

```bash
./add-images.sh content/posts/2026-11-20_My-Post
```

The script preserves existing Markdown and image order, appends only new files
in stable filename order, supports mixed-case JPG/JPEG/PNG/WebP extensions,
creates a protected backup only when it changes the post, and replaces the file
atomically. It never invents alt descriptions. Fill in each generated `alt=""`
with a short description of the photograph.

### Interim alt-text policy

Photographs are the site's primary content, so filename-derived or missing alt
text is not treated as decorative. Until a real description is written, the
rendered fallback is an honest, unique label such as:

`Uzbekistan — untitled photograph 1 (description pending)`

This conveys series context and position without fabricating visual details. It
is an interim accessibility measure, not a completed description. Genuine
author-written alt text is preserved verbatim. Generate the actionable backlog
with:

```bash
./scripts/audit-alt-text.sh --output alt-text-audit.tsv
```

Use `--strict` when a zero-backlog policy becomes practical. The current legacy
content intentionally does not pass strict mode.

## Local build and tests

Run the lightweight regression suite:

```bash
./tests/run-tests.sh
```

Run the production build locally:

```bash
hugo --minify --gc --cleanDestinationDir
```

The build fails when a shortcode or featured card references a required image
that does not exist. Generated output in `public/` and Hugo's `resources/` cache
are ignored by Git.

## Deploy

Create `.env` with `BUCKET` and `DIST_ID`, then preview first:

```bash
./deploy.sh --dry-run
```

Deploy only after reviewing the preview:

```bash
./deploy.sh
```

The deployment script rebuilds the site, synchronizes `public/` with
`aws s3 sync --delete`, and invalidates changed HTML/XML plus fixed entry points
and `robots.txt`.

### Known ImageOptim limitation

Do not assume a manual ImageOptim pass over `public/` will survive deployment.
`deploy.sh` runs Hugo again, and Hugo can restore generated files from
`resources/_gen`, overwriting the optimized bytes. Redesigning the build →
ImageOptim → sync workflow is deliberately deferred to Phase 2. Until then,
compare hashes or file sizes after the deploy build if ImageOptim output matters.
