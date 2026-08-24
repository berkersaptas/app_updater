#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

command -v java >/dev/null || { echo "java is required" >&2; exit 1; }
command -v javac >/dev/null || { echo "javac is required" >&2; exit 1; }

base="$work_dir/base.so"
patched="$work_dir/patched.so"
diff="$work_dir/patched.so.diff"
reconstructed="$work_dir/reconstructed.so"

# Simulate a base AOT library and a patched one with a small localized change, the way a real
# libapp.so diff between two close Dart AOT builds would look.
head -c 200000 /dev/urandom > "$base"
cp "$base" "$patched"
python3 -c "
with open('$patched', 'r+b') as f:
    f.seek(50000)
    f.write(b'PATCHED_REGION_CHANGE_1234567890')
"

"$repo_dir/scripts/generate_binary_diff.sh" "$base" "$patched" "$diff"

cache_dir="${OTA_BSDIFF_CACHE_DIR:-$repo_dir/.cache/jbsdiff}"
jbsdiff_jar="$cache_dir/jbsdiff-1.0.jar"
commons_compress_jar="$cache_dir/commons-compress-1.21.jar"
classpath="$jbsdiff_jar:$commons_compress_jar"

# Apply the diff using the exact same io.sigpipe.jbsdiff.Patch.patch(byte[], byte[], OutputStream)
# API that ota_runtime_android's BinaryDiffArtifactResolver calls on-device, to prove the
# build-time-generated diff round-trips through the same library used at apply time.
cat > "$work_dir/ApplyDiff.java" <<'EOF'
import io.sigpipe.jbsdiff.Patch;
import java.io.ByteArrayOutputStream;
import java.nio.file.Files;
import java.nio.file.Paths;

public class ApplyDiff {
    public static void main(String[] args) throws Exception {
        byte[] base = Files.readAllBytes(Paths.get(args[0]));
        byte[] diff = Files.readAllBytes(Paths.get(args[1]));
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        Patch.patch(base, diff, out);
        Files.write(Paths.get(args[2]), out.toByteArray());
    }
}
EOF
javac -cp "$classpath" -d "$work_dir" "$work_dir/ApplyDiff.java"
java -cp "$work_dir:$classpath" ApplyDiff "$base" "$diff" "$reconstructed"

cmp -s "$patched" "$reconstructed" || {
  echo "Reconstructed artifact does not match the patched artifact" >&2
  exit 1
}

diff_size="$(wc -c < "$diff" | tr -d ' ')"
patched_size="$(wc -c < "$patched" | tr -d ' ')"
[[ "$diff_size" -lt "$patched_size" ]] || {
  echo "Diff ($diff_size bytes) was not smaller than the full artifact ($patched_size bytes)" >&2
  exit 1
}

echo "binary_diff round-trip is valid ($diff_size byte diff vs $patched_size byte artifact)"
