#!/usr/bin/env bash
# Builds the type-neutral update image (firmware/update/ElectroBright_Update:
# the universal firmware without a default type) for wireless updates, with the
# Arduino IDE's own arduino-cli and configuration, and writes next to it:
#   ElectroBright_Update-<version>.bin    the app image (what the phone sends)
#   ElectroBright_Update-<version>.json   {"version", "size", "sha256"}
#
#   tools/build_update_image.sh                 into firmware/update/dist/
#   OUT_DIR=/some/dir tools/build_update_image.sh
#
# Rollback test images (for the app's debug builds only; never a release):
#   tools/build_update_image.sh --rollback-test fail     fails its first-boot self-check
#   tools/build_update_image.sh --rollback-test freeze   freezes before it (task watchdog)
# They carry kRollbackTestVersion (Config.h) and are written as
#   ElectroBright_RollbackTest-<fail|freeze>-<version>.bin / .json
set -euo pipefail

TEST_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rollback-test)
      TEST_MODE="${2:-}"
      [[ "$TEST_MODE" == fail || "$TEST_MODE" == freeze ]] || { echo "--rollback-test takes fail or freeze" >&2; exit 2; }
      shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

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

CONFIG_H="$FW/core/ElectroBrightCore/src/config/Config.h"
VERSION="$(sed -n 's/.*kFirmwareVersion = "\([0-9.]*\)".*/\1/p' "$CONFIG_H")"
[[ -n "$VERSION" ]] || { echo "kFirmwareVersion not found in Config.h" >&2; exit 1; }
PROPS=()
NAME="ElectroBright_Update-$VERSION"
TEST_BYTE=0
if [[ -n "$TEST_MODE" ]]; then
  VERSION="$(sed -n 's/.*kRollbackTestVersion = "\([0-9.]*\)".*/\1/p' "$CONFIG_H")"
  [[ -n "$VERSION" ]] || { echo "kRollbackTestVersion not found in Config.h" >&2; exit 1; }
  [[ "$TEST_MODE" == fail ]] && TEST_BYTE=1 || TEST_BYTE=2
  PROPS=(--build-property "compiler.cpp.extra_flags=-DEB_ROLLBACK_TEST=$TEST_BYTE"
         --build-property "compiler.c.extra_flags=-DEB_ROLLBACK_TEST=$TEST_BYTE")
  NAME="ElectroBright_RollbackTest-$TEST_MODE-$VERSION"
fi

echo "== $NAME"
"$CLI" "${CFG[@]}" compile --fqbn "$FQBN" --warnings all ${PROPS[@]+"${PROPS[@]}"} \
  --library "$FW/core/ElectroBrightCore" --build-path "$BUILD" "$SKETCH" 2>&1 \
  | grep -E "Sketch uses|Global variables|error|warning:" || true
BIN="$BUILD/ElectroBright_Update.ino.bin"
[[ -f "$BIN" ]] || { echo "build failed" >&2; exit 1; }

# The image must carry the identity block the lights check (and the test mark).
python3 - "$BIN" "$VERSION" "$TEST_BYTE" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
i = data.find(b"EBIMGID1", 0, 1024)
if i < 0 or data[i + 8:i + 21] != b"ElectroBright" or data[i + 36:i + 52].split(b"\0")[0] != sys.argv[2].encode():
    sys.exit("the image has no ElectroBright identity block of version " + sys.argv[2])
if data[i + 52] != int(sys.argv[3]):
    sys.exit("the image's rollback-test mark is %d, expected %s" % (data[i + 52], sys.argv[3]))
PY

mkdir -p "$OUT_DIR"
cp "$BIN" "$OUT_DIR/$NAME.bin"
SIZE="$(wc -c < "$OUT_DIR/$NAME.bin" | tr -d ' ')"
SHA="$(shasum -a 256 "$OUT_DIR/$NAME.bin" | cut -d' ' -f1)"
printf '{"version": "%s", "size": %s, "sha256": "%s", "rollbackTest": %s}\n' "$VERSION" "$SIZE" "$SHA" "$TEST_BYTE" > "$OUT_DIR/$NAME.json"
echo "   $OUT_DIR/$NAME.bin"
echo "   version $VERSION, $SIZE bytes, sha256 $SHA"
