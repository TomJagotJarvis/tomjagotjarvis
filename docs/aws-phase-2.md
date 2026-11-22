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
2. **Run the cache metadata migration separately.** Native `hugo deploy`
   deliberately skips unchanged content even when its metadata differs. After
   versioning is enabled, use the reviewed one-time `--force` procedure in the
   README to apply the cache metadata to every existing object. Normal
   deployments must not use `--force`.
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
not override the S3 cache directives established in `config.toml`.

## Clean URLs and invalidations

The deployment target keeps `index.html` object keys, so the viewer-request
rewrite continues to provide clean URLs. Native Hugo deployment invalidates
`/*` after a successful changed deployment. This covers both viewer and
rewritten origin paths without custom output parsing. A wildcard counts as one
invalidation path and is proportionate for this occasionally deployed site.

## Rollback and operational limits

Native `hugo deploy` compares object size and MD5 checksum, uploads new or
changed files, and deletes remote objects absent from the clean local build. It
is not transactional: a failure can leave a partially updated bucket, but Hugo
does not invalidate CloudFront after a failed transfer. Its default deletion
limit skips all deletions if more than 256 are proposed. Bucket versioning is
the recommended recovery mechanism; versioned-prefix deployments would add
disproportionate complexity.

No remote lock or stored transfer plan is maintained. The dry run is a preview,
not a transaction: another writer could alter the bucket before deployment.
The confirmed deployment recalculates its plan, but S3 should remain
single-writer and preview and deployment should be run close together.

The deployment IAM user can read the distribution but was denied
`cloudfront:GetCachePolicy`, `cloudfront:DescribeFunction` and
`cloudfront:GetFunction`. Review the function source and policy details with an
administrator identity before making the proposed live changes.
