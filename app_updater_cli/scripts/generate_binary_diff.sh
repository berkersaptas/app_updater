#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <base-libapp.so> <patched-libapp.so> <output-diff>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
base_artifact="$1"
patched_artifact="$2"
output_diff="$3"

[[ -f "$base_artifact" ]] || { echo "Base artifact not found: $base_artifact" >&2; exit 1; }
[[ -f "$patched_artifact" ]] || { echo "Patched artifact not found: $patched_artifact" >&2; exit 1; }
command -v java >/dev/null || { echo "java is required to generate a binary diff" >&2; exit 1; }

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${OTA_BSDIFF_CACHE_DIR:-$repo_dir/.cache/jbsdiff}"
maven_base="https://repo1.maven.org/maven2"
jbsdiff_version="1.0"
commons_compress_version="1.21"
jbsdiff_jar="$cache_dir/jbsdiff-$jbsdiff_version.jar"
commons_compress_jar="$cache_dir/commons-compress-$commons_compress_version.jar"

mkdir -p "$cache_dir"
if [[ ! -f "$jbsdiff_jar" ]]; then
  curl -fsSL -o "$jbsdiff_jar.tmp" \
    "$maven_base/io/sigpipe/jbsdiff/$jbsdiff_version/jbsdiff-$jbsdiff_version.jar"
  mv "$jbsdiff_jar.tmp" "$jbsdiff_jar"
fi
if [[ ! -f "$commons_compress_jar" ]]; then
  curl -fsSL -o "$commons_compress_jar.tmp" \
    "$maven_base/org/apache/commons/commons-compress/$commons_compress_version/commons-compress-$commons_compress_version.jar"
  mv "$commons_compress_jar.tmp" "$commons_compress_jar"
fi

mkdir -p "$(dirname "$output_diff")"
rm -f "$output_diff"
java -cp "$jbsdiff_jar:$commons_compress_jar" io.sigpipe.jbsdiff.ui.CLI \
  diff "$base_artifact" "$patched_artifact" "$output_diff"

echo "Binary diff: $output_diff ($(wc -c < "$output_diff" | tr -d ' ') bytes)"
