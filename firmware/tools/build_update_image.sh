#!/usr/bin/env bash
# Builds the type-neutral update image (firmware/update/ElectroBright_Update:
# the universal firmware without a default type) for wireless updates, with the
# Arduino IDE's own arduino-cli and configuration, and writes next to it:
#   ElectroBright_Update-<version>.bin    the app image (what the phone sends)
#   ElectroBright_Update-<version>.json   {"version", "size", "sha256"}
#
#   tools/build_update_image.sh                 into firmware/update/dist/
#   OUT_DIR=/some/dir tools/build_update_image.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/.." && pwd)"
CLI="${ARDUINO_CLI:-/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli}"
CONFIG="${ARDUINO_CONFIG:-$HOME/.arduinoIDE/arduino-cli.yaml}"
FQBN="esp32:esp32:esp32c3:CDCOnBoot=cdc"
SKETCH="$FW/update/ElectroBright_Update"
OUT_DIR="${OUT_DIR:-$FW/update/dist}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

[[ -x "$CLI" ]] || CLI="$(command -v arduino-cli || true)"
[[ -n "$CLI" ]] || { echo "arduino-cli not found (install the Arduino IDE or set ARDUINO_CLI)" >&2; exit 1; }
CFG=()
[[ -f "$CONFIG" ]] && CFG=(--config-file "$CONFIG")

VERSION="$(sed -n 's/.*kFirmwareVersion = "\([0-9.]*\)".*/\1/p' "$FW/core/ElectroBrightCore/src/config/Config.h")"
[[ -n "$VERSION" ]] || { echo "kFirmwareVersion not found in Config.h" >&2; exit 1; }

echo "== ElectroBright_Update $VERSION"
"$CLI" "${CFG[@]}" compile --fqbn "$FQBN" --warnings all \
  --library "$FW/core/ElectroBrightCore" --build-path "$BUILD" "$SKETCH" 2>&1 \
  | grep -E "Sketch uses|Global variables|error|warning:" || true
BIN="$BUILD/ElectroBright_Update.ino.bin"
[[ -f "$BIN" ]] || { echo "build failed" >&2; exit 1; }

# The image must carry the identity block the lights check.
python3 - "$BIN" "$VERSION" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"EBIMGID1", 0, 1024)
if i < 0 or data[i + 8:i + 21] != b"ElectroBright" or not data[i + 36:i + 52].startswith(sys.argv[2].encode()):
    sys.exit("the image has no ElectroBright identity block of version " + sys.argv[2])
PY

mkdir -p "$OUT_DIR"
NAME="ElectroBright_Update-$VERSION"
cp "$BIN" "$OUT_DIR/$NAME.bin"
SIZE="$(wc -c < "$OUT_DIR/$NAME.bin" | tr -d ' ')"
SHA="$(shasum -a 256 "$OUT_DIR/$NAME.bin" | cut -d' ' -f1)"
printf '{"version": "%s", "size": %s, "sha256": "%s"}\n' "$VERSION" "$SIZE" "$SHA" > "$OUT_DIR/$NAME.json"
echo "   $OUT_DIR/$NAME.bin"
echo "   version $VERSION, $SIZE bytes, sha256 $SHA"
