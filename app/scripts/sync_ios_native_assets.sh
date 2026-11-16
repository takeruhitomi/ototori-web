#!/bin/sh
# Sync native iOS resources from the Android assets (single source of truth).
# Run from apps/choir_mobile on macOS:  sh scripts/sync_ios_native_assets.sh
# Optionally embed the model bundle ZIP for local testing:
#   CHOIR_MODEL_BUNDLE=/path/homr-0.7.zip sh scripts/sync_ios_native_assets.sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app_root=$(CDPATH= cd -- "$here/../.." && pwd)      # apps/choir_mobile
android_assets="$app_root/android/app/src/main/assets"
dest="$app_root/ios/Runner/NativeAssets"

mkdir -p "$dest/omr" "$dest/piano"
cp "$android_assets/omr/vocabulary.json" "$dest/omr/vocabulary.json"
cp "$android_assets"/piano/*.pcm "$dest/piano/"
cp "$android_assets/piano/ATTRIBUTION.txt" "$dest/piano/ATTRIBUTION.txt"

# Drop a stale bundled model unless it is being (re)installed now.
if [ -n "${CHOIR_MODEL_BUNDLE:-}" ]; then
  if [ -f "$CHOIR_MODEL_BUNDLE" ]; then
    cp "$CHOIR_MODEL_BUNDLE" "$dest/models.zip"
    echo "bundled $CHOIR_MODEL_BUNDLE -> $dest/models.zip"
  else
    echo "CHOIR_MODEL_BUNDLE does not exist: $CHOIR_MODEL_BUNDLE" >&2
    exit 1
  fi
else
  rm -f "$dest/models.zip"
fi

# Parity check: iOS copies must hash-match the Android originals.
( cd "$android_assets" && shasum -a 256 omr/vocabulary.json piano/*.pcm ) | \
( cd "$dest" && shasum -a 256 -c - )
echo "synced ios/Runner/NativeAssets"
