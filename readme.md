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

This records the build time and Git commit. It does not contact AWS. Next, open
the generated output in ImageOptim:

```bash
open -a ImageOptim public/
```

Wait until ImageOptim's queue has completely finished. The app's documented
direct command-line executable is not used because ImageOptim 1.9.3 aborted in
a controlled macOS test; `open -a` is asynchronous, so completion must be
confirmed in the app.

Preview the optimised directory without rebuilding it:

```bash
./deploy.sh --dry-run
```

Review every upload, deletion and invalidation, then deploy that same output:

```bash
./deploy.sh
```

Both preview and deployment use the already-built `public/`; neither invokes
Hugo. The script rejects a changed Git commit, source files newer than the build,
and backup, temporary or `.DS_Store` files. This timestamp check is intentionally
simple. Rebuild after restoring sources with preserved timestamps or whenever
there is any doubt about whether `public/` is current.

Immediately before each sync, the script touches all generated photographs in
`public/originals/`. This makes them newer than their S3 objects, ensuring the
ImageOptim bytes are uploaded despite the AWS CLI's size-and-mtime comparison.
The deliberate trade-off is that every generated photograph is uploaded on an
occasional deployment. For this personal site, that predictable behaviour is
preferred to SHA manifests, hard-linked staging and additional deployment state.

The dry run cannot upload, delete or invalidate anything. It does update local
generated-image modification times, but never changes their bytes.

### Cache policy

The deploy script uses three non-overlapping S3 sync passes, each retaining
`--delete` within its own file class:

- fingerprinted CSS and Hugo `_hu_` images: `public,max-age=31536000,immutable`;
- HTML, XML and `robots.txt`: `public,max-age=0,s-maxage=300,must-revalidate`;
- any remaining static files: `public,max-age=86400`.

The first deployment re-uploads the freshly built documents and deliberately
touched images, so these objects receive the new metadata without a separate
migration mode. Review that first dry run carefully; it will be substantially
larger than later content-only previews.

After a successful deployment, the script invalidates `/*`. One wildcard is
easy to reason about and covers clean viewer URLs, rewritten origin paths,
changed pages and deletions. For an occasional personal-site deployment, this
is preferable to maintaining output-parsing and targeted-invalidation logic.

### Recovery and checks

If source files change, start again with `--build-only`. The ignored
`.deploy/build-ready` marker is the only local state. Delete `.deploy/` to force
a fresh build. Source photographs and Hugo's `resources/` cache are never
modified by these scripts.

The bucket is assumed to have a single writer. It can change between the
reviewed dry run and deployment, so run them close together and repeat the dry
run if anything else may have written to S3. Likewise, rerun the preview if
`public/` changes after it—especially if ImageOptim was still running.

The read-only AWS review and proposed CloudFront, redirect, security-header and
bucket-versioning changes are documented in
[`docs/aws-phase-2.md`](docs/aws-phase-2.md). Those changes are not applied by
the repository scripts.
