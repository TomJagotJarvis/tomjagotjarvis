# Tom Jagot-Jarvis photography website

This is a Hugo static photography site deployed to Amazon S3 behind CloudFront.
Posts are photo stories with responsive image variants generated from the source
JPEGs in `assets/originals/`.

## Requirements

- Hugo Extended. Phase 1 was tested with `hugo v0.167.0+extended+withdeploy`.
- macOS Bash 3.2 or newer for the repository scripts.
- ImageOptim for the final generated-image pass.
- AWS credentials available through the standard AWS SDK credential chain. The
  AWS CLI is useful for the separately approved infrastructure steps.

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

The production S3 target, CloudFront distribution and cache policies are in
`config.toml`. The bucket name and distribution ID are public infrastructure
identifiers, not credentials. Keep AWS credentials in the usual local AWS
profile or environment variables; they are never committed. An ignored `.env`
may still define `BUCKET` and `DIST_ID` for one-time AWS CLI administration, but
the normal deployment does not need it.

Deployment deliberately has four separate steps. This ensures that ImageOptim
runs after Hugo and that `hugo deploy` reads the optimised output without
rebuilding it.

1. Create a clean production build:

```bash
./deploy.sh --build-only
```

   This records the build time and Git commit. It does not contact AWS.

2. Open the generated output in ImageOptim:

```bash
open -a ImageOptim public/
```

   Wait until ImageOptim's queue has completely finished. The app's executable
   is not used as a deployment CLI because ImageOptim 1.9.3 aborted in a
   controlled macOS test; `open -a` is asynchronous, so completion must be
   confirmed in the app.

3. Preview the optimised directory:

```bash
./deploy.sh --dry-run
```

   Hugo compares local and S3 content using size and MD5 checksums. Unchanged
   generated images are skipped even when Hugo or ImageOptim changed their
   timestamps. The dry run cannot upload, delete or invalidate anything.

4. Review the preview, then deploy that same output:

```bash
./deploy.sh
```

The final command shows a fresh plan and asks for confirmation. Hugo's default
limit skips all deletions if more than 256 would be required. Both preview and
deployment use the already-built `public/`; `hugo deploy` does not run a site
build. The wrapper rejects a changed Git commit, source files newer than the
build, and backup, temporary or `.DS_Store` files. Rebuild after restoring
sources with preserved timestamps or whenever there is any doubt about whether
`public/` is current.

The wrapper intentionally has no `--force` option and explicitly disables an
inherited `HUGO_DEPLOYMENT_FORCE` setting. Normal deployments upload only new
files and files whose content checksum changed.

### Cache policy

Hugo applies the first matching deployment rule in `config.toml`:

- fingerprinted CSS and Hugo `_hu_` images: `public,max-age=31536000,immutable`;
- HTML, XML and `robots.txt`: `public,max-age=0,s-maxage=300,must-revalidate`;
- any remaining static files: `public,max-age=86400`.

The deployment target retains `index.html` object keys. The existing CloudFront
viewer-request function therefore continues to provide clean URLs. After a
successful changed deployment, Hugo invalidates `/*`, covering clean viewer
URLs, rewritten origin paths, changed pages and deletions.

### ImageOptim and immutable image URLs

Hugo chooses each generated `_hu_` image URL before ImageOptim runs. ImageOptim
can therefore change a JPEG's bytes without changing its URL. `hugo deploy`
detects and uploads those changed bytes, and the CloudFront invalidation removes
the old edge copy, but a browser may retain the old same-URL response for the
one-year immutable lifetime.

This is acceptable while ImageOptim is used for lossless recompression: the old
and new files are visually equivalent. Any change intended to alter visible
pixels must also produce a new Hugo-generated URL. If that rule cannot be kept,
generated images should use a shorter, non-immutable cache policy.

### One-time cache metadata migration

Existing S3 objects do not have the new `Cache-Control` metadata. Hugo does not
re-upload an unchanged object merely because its metadata differs, which keeps
normal deployments incremental. After S3 versioning has been enabled and the
migration has been separately approved:

1. Complete the clean build and ImageOptim steps above.
2. Review the normal `./deploy.sh --dry-run` output.
3. Preview the one-time forced metadata update:

   ```bash
   hugo deploy --target production --dryRun --force
   ```

4. Review the complete object list and total size, then run the migration:

   ```bash
   hugo deploy --target production --force
   ```

The second command still prompts for confirmation because `confirm = true` is
set in `config.toml`. Expect every deployed object—currently about 1.7 GB—to be
uploaded once. Do not add `force` to `config.toml`; all later deployments should
return to the normal four-step workflow.

### Recovery and checks

If source files change, start again with `--build-only`. The ignored
`.deploy/build-ready` marker is the only local state. Delete `.deploy/` to force
a fresh build. Source photographs and Hugo's `resources/` cache are never
modified by these scripts.

The bucket is assumed to have a single writer. It can change between preview
and deployment. The final command recalculates and displays the current plan,
but repeat the dry run if anything else may have written to S3. Likewise, rerun
the preview if `public/` changes after it—especially if ImageOptim was still
running.

The read-only AWS review and proposed CloudFront, redirect, security-header and
bucket-versioning changes are documented in
[`docs/aws-phase-2.md`](docs/aws-phase-2.md). Those changes are not applied by
the repository scripts.
