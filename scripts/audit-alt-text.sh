#!/bin/bash
set -euo pipefail

STRICT=0
OUTPUT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --output)
      shift
      if [ "$#" -eq 0 ]; then
        echo "Error: --output requires a path" >&2
        exit 2
      fi
      OUTPUT=$1
      ;;
    -h|--help)
      echo "Usage: $0 [--strict] [--output FILE]"
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp_file=$(mktemp "${TMPDIR:-/tmp}/alt-text-audit.XXXXXX")
trap 'rm -f -- "$tmp_file"' EXIT HUP INT TERM

for file in "$ROOT"/content/posts/*/index.md; do
  perl -ne '
    while (/\{\{<\s+responsive-img\b(.*?)>\}\}/g) {
      my $attrs = $1;
      my ($src) = $attrs =~ /\bsrc="([^"]+)"/;
      my ($alt) = $attrs =~ /\balt="([^"]*)"/;
      next unless defined $src;
      $alt = "" unless defined $alt;
      my $src_base = lc $src;
      $src_base =~ s{^.*/}{};
      $src_base =~ s{\.(?:jpe?g|png|webp)$}{}i;
      my $alt_base = lc $alt;
      $alt_base =~ s{\.(?:jpe?g|png|webp)$}{}i;
      (my $normalized_src = $src_base) =~ s{[^a-z0-9]}{}g;
      (my $normalized_alt = $alt_base) =~ s{[^a-z0-9]}{}g;
      if ($normalized_alt eq "" || $normalized_alt eq $normalized_src) {
        print "$ARGV\t$.\t$src\t$alt\n";
      }
    }
  ' "$file" >> "$tmp_file"
done

count=$(wc -l < "$tmp_file" | tr -d ' ')
{
  printf 'file\tline\tsource\tcurrent_alt\n'
  sed "s#^$ROOT/##" "$tmp_file"
  printf '\n%d photograph(s) need a descriptive alt text.\n' "$count"
  printf 'Interim HTML identifies these as untitled photographs with series context and position; it does not invent visual descriptions.\n'
} > "${OUTPUT:-/dev/stdout}"

if [ "$STRICT" -eq 1 ] && [ "$count" -gt 0 ]; then
  exit 1
fi
