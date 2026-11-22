# Phase 2 AWS review and proposed changes

This document records the read-only inspection performed on 21 November 2026.
No AWS resource or production object was changed.

## Observed configuration

- One enabled CloudFront distribution serves both `tomjagotjarvis.com` and
  `www.tomjagotjarvis.com` from the S3 REST endpoint in `eu-west-2`.
- The default behavior redirects HTTP to HTTPS and uses AWS's managed
  `CachingOptimized` cache policy (`658327ea-f89d-4fab-a63d-7e88639e58f6`).
- A viewer-request CloudFront Function named `RewriteDefaultIndexRequest` is
  associated with the behavior. Live read-only checks confirmed that clean,
  trailing-slash and `/index.html` page forms all resolve. The deployment IAM
  user cannot read the function source, so its exact implementation was not
  independently reviewed.
- No response-headers policy is attached.
- The S3 bucket does not have versioning enabled.
- Sample HTML, CSS, XML, JPEG and `robots.txt` objects had no explicit
  `Cache-Control` metadata before this work.
- Both the apex and `www` hostnames currently return the site with status 200;
  `www` is not redirected.

## Recommended one-time actions

These are proposals for explicit owner approval. They are not performed by
`deploy.sh` and were not applied during Phase 2.

1. **Enable S3 bucket versioning.** This provides proportionate recovery from
   an accidental upload or `--delete`. Add a lifecycle policy for old versions
   if storage growth becomes material. After reviewing the bucket name, the
   one-time command is:

   ```bash
   aws s3api put-bucket-versioning \
     --bucket "$BUCKET" \
     --versioning-configuration Status=Enabled
   ```
2. **Run the metadata migration once.** Prepare and optimise a current build,
   review `./deploy.sh --skip-build --dry-run --refresh-metadata`, then run the
   matching non-dry command. It re-uploads unchanged objects so they receive the
   new metadata and invalidates `/*` once.
3. **Add a `www` → apex redirect.** Extend or replace the viewer-request
   CloudFront Function so requests whose `Host` is `www.tomjagotjarvis.com`
   return a permanent redirect to the same path and query on
   `https://tomjagotjarvis.com`. Test in the function's development stage
   before publishing. Keep the current apex canonical URLs.
4. **Attach a response-headers policy.** A proportionate starting policy is:
   - `Strict-Transport-Security: max-age=31536000` (do not add
     `includeSubDomains` or preload until every subdomain is confirmed HTTPS);
   - `X-Content-Type-Options: nosniff`;
   - `Referrer-Policy: strict-origin-when-cross-origin`;
   - `X-Frame-Options: DENY` or CSP `frame-ancestors 'none'`;
   - a Content Security Policy tested in report-only mode first.

   A starting CSP must account for the site's own assets, Google Fonts and
   Cloudflare Web Analytics. For example:

   ```text
   default-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none';
   img-src 'self' data:; style-src 'self' https://fonts.googleapis.com;
   font-src 'self' https://fonts.gstatic.com;
   script-src 'self' https://static.cloudflareinsights.com;
   connect-src 'self' https://cloudflareinsights.com;
   form-action 'self'; upgrade-insecure-requests
   ```

   Validate analytics and font loading before enforcing it.

## CloudFront cache policy

No cache-policy change is currently required. The managed optimized policy has
the appropriate broad TTL range for origin `Cache-Control` directives to select
short caching for documents and one-year caching for fingerprinted assets.
Keep the policy unless a later inspection identifies a behavior-specific need.
A response-headers policy is separate: it can add security headers but should
not be used to override the S3 cache directives established by `deploy.sh`.

## Clean URLs and invalidations

The viewer-request rewrite runs before cache lookup. AWS recommends invalidating
both a viewer URI and the rewritten origin URI. Normal deployments therefore
derive all of these forms from changed or deleted `*/index.html` objects:

- `/posts/example/index.html`
- `/posts/example/`
- `/posts/example`

Root `index.html`, XML feeds, the sitemap and `robots.txt` are invalidated when
their corresponding objects change. New, modified and deleted objects are all
parsed from the S3 dry-run/sync output. Hashed CSS and image names are immutable
and need no targeted invalidation.

## Rollback and operational limits

Filtered sync passes retain `--delete`, which is required to remove obsolete
hashed images and deleted pages. S3 sync is not transactional: a failure can
leave a partially updated bucket, but the script stops before invalidation.
Bucket versioning is the recommended recovery mechanism for this personal site;
versioned-prefix deployments would add disproportionate complexity.

AWS CLI local-to-S3 sync decides whether to upload from object existence, size
and modification time; `--exact-timestamps` only changes S3-to-local download
comparison. ImageOptim can therefore produce different bytes that an ordinary
sync might miss. The repository stores the clean-build SHA-256 manifest and
force-uploads only files whose generated bytes changed before running the
filtered syncs.

The reviewed dry run also records the remote transfer plan. A deployment repeats
the dry run immediately before applying and stops if that plan differs. This is
not a lock: another writer could still alter the bucket between the preflight
and the individual upload/delete calls. Deploy only when no other process is
writing to the bucket, and use bucket versioning for recovery.

The deployment IAM user can read the distribution but was denied
`cloudfront:GetCachePolicy`, `cloudfront:DescribeFunction` and
`cloudfront:GetFunction`. Review the function source and policy details with an
administrator identity before making the proposed live changes.
