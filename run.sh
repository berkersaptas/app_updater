#!/bin/sh
set -eu

PUBLIC_DIR="../app_updater_public_clean"

if [ -e "$PUBLIC_DIR" ]; then
  echo "Hata: $PUBLIC_DIR zaten mevcut."
  exit 1
fi

mkdir "$PUBLIC_DIR"

git ls-files -co --exclude-standard |
while IFS= read -r file; do
  if [ -f "$file" ]; then
    printf '%s\n' "$file"
  fi
done |
rsync -a --files-from=- ./ "$PUBLIC_DIR/"

echo "Temiz public kopya hazır: $PUBLIC_DIR"
