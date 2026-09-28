#!/usr/bin/env bash
# Bundles the wireless-update image into the app: builds it with
# firmware/tools/build_update_image.sh and puts it in app/assets/firmware/
# with manifest.json (version, size, SHA-256, product, image kind, file).
# The app reads the manifest at start; test/cross_repo/firmware_bundle_test
# checks it against the bundled file and the firmware version constant.
#
#   tool/bundle_firmware.sh
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
DEST="$APP/assets/firmware"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

OUT_DIR="$BUILD" "$ROOT/firmware/tools/build_update_image.sh"
JSON="$(ls "$BUILD"/ElectroBright_Update-*.json)"
BIN="${JSON%.json}.bin"
[[ -f "$BIN" ]] || { echo "no update image was built" >&2; exit 1; }

mkdir -p "$DEST"
rm -f "$DEST"/*.bin "$DEST/manifest.json"
cp "$BIN" "$DEST/"
python3 - "$JSON" "$(basename "$BIN")" "$DEST/manifest.json" <<'PY'
import json, sys
built = json.load(open(sys.argv[1]))
manifest = {
    "product": "ElectroBright",
    "kind": "universal",
    "version": built["version"],
    "size": built["size"],
    "sha256": built["sha256"],
    "file": sys.argv[2],
}
with open(sys.argv[3], "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
echo "   bundled into $DEST:"
cat "$DEST/manifest.json"
