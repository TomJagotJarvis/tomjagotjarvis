# Tom Jagot-Jarvis photography website

This is a Hugo static photography site deployed to Amazon S3 behind CloudFront.
Posts are photo stories with responsive image variants generated from the source
JPEGs in `assets/originals/`.

## Requirements

- Hugo Extended. Phase 1 was tested with `hugo v0.167.0+extended+withdeploy`.
- macOS Bash 3.2 or newer for the repository scripts.
- ImageOptim for the final generated-image pass.
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

Create `.env` with `BUCKET` and `DIST_ID`. The deployment is deliberately split
into build, optimisation, preview and apply stages so that Hugo never rebuilds
over ImageOptim's output.

First create a clean production build:

```bash
./deploy.sh --build-only
```

This records a fingerprint of all Hugo inputs. It does not contact AWS. Next,
open the generated output in ImageOptim:

```bash
open -a ImageOptim public/
```

Wait until ImageOptim's queue has completely finished. The app's documented
direct command-line executable is not used because ImageOptim 1.9.3 aborted in
a controlled macOS test; `open -a` is asynchronous, so completion must be
confirmed in the app.

Preview the exact optimised directory without rebuilding it:

```bash
./deploy.sh --skip-build --dry-run
```

Review every upload, deletion and invalidation, then deploy that same output:

```bash
./deploy.sh --skip-build
```

The final command refuses to run unless:

- the source fingerprint still matches the recorded build;
- `public/` exactly matches the preceding dry-run preview;
- the preview used the same bucket, distribution and metadata mode; and
- no backup, temporary or `.DS_Store` files are present.

The dry run cannot upload, delete or invalidate anything. It also never runs
Hugo, so it cannot overwrite an optimised image. If ImageOptim or another
process changes `public/` during or after the preview, deployment stops.

### Cache policy

The deploy script uses three non-overlapping S3 sync passes, each retaining
`--delete` within its own file class:

- fingerprinted CSS and Hugo `_hu_` images: `public,max-age=31536000,immutable`;
- HTML, XML and `robots.txt`: `public,max-age=0,s-maxage=300,must-revalidate`;
- any remaining static files: `public,max-age=86400`.

New and changed objects receive these headers automatically. Normal
`aws s3 sync` does not update metadata on unchanged objects, so the existing
bucket needs a one-time refresh. Preview it only after completing the normal
build and ImageOptim steps:

```bash
./deploy.sh --skip-build --dry-run --refresh-metadata
```

After explicit approval, apply the migration with the matching command:

```bash
./deploy.sh --skip-build --refresh-metadata
```

This re-uploads the prepared files with their cache class, removes stale files
using the normal filtered syncs, and uses a one-time `/*` invalidation so cached
responses receive the new headers. Do not run the migration casually: it
uploads the entire site and consumes a full invalidation.

For normal deployments, changed and deleted page objects generate targeted
invalidations for both the origin path (`/posts/example/index.html`) and clean
viewer paths (`/posts/example/` and `/posts/example`). Fingerprinted assets do
not need invalidation.

### Recovery and checks

If source files change, start again with `--build-only`. If only `public/`
changes after a preview, repeat the dry run. Deployment state is stored under
the ignored `.deploy/` directory. Delete that directory to force a completely
fresh preparation cycle; source photographs and Hugo's `resources/` image cache
are never modified by these scripts.

The read-only AWS review and proposed CloudFront, redirect, security-header and
bucket-versioning changes are documented in
[`docs/aws-phase-2.md`](docs/aws-phase-2.md). Those changes are not applied by
the repository scripts.
