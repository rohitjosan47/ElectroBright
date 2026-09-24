#!/usr/bin/env bash
# Compiles fixture sketches for the ESP32-C3 with the Arduino IDE's own
# arduino-cli and configuration (same cores and libraries as the IDE), always
# against the working-tree core.
#
#   tools/build.sh                 build every fixture
#   tools/build.sh RGB RGBW        build selected fixtures (folder suffix)
#   OUT=/tmp/eb tools/build.sh     keep build outputs (default: a temp folder)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/.." && pwd)"
CLI="${ARDUINO_CLI:-/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli}"
CONFIG="${ARDUINO_CONFIG:-$HOME/.arduinoIDE/arduino-cli.yaml}"
FQBN="esp32:esp32:esp32c3:CDCOnBoot=cdc"
OUT="${OUT:-$(mktemp -d)}"

[[ -x "$CLI" ]] || CLI="$(command -v arduino-cli || true)"
[[ -n "$CLI" ]] || { echo "arduino-cli not found (install the Arduino IDE or set ARDUINO_CLI)" >&2; exit 1; }
CFG=()
[[ -f "$CONFIG" ]] && CFG=(--config-file "$CONFIG")

# The IDE compiles against the installed library; warn when that is a stale copy.
"$HERE/install_ide_core.sh" --status | grep -q STALE && echo "warning: the Arduino IDE's ElectroBrightCore copy is stale; run tools/install_ide_core.sh" >&2

if [[ $# -gt 0 ]]; then
  FIXTURES=()
  for f in "$@"; do FIXTURES+=("$FW/fixtures/ElectroBright_$f"); done
else
  FIXTURES=("$FW"/fixtures/ElectroBright_*)
fi

status=0
for dir in "${FIXTURES[@]}"; do
  name="$(basename "$dir")"
  [[ -f "$dir/$name.ino" ]] || { echo "no sketch $dir/$name.ino" >&2; status=1; continue; }
  echo "== $name"
  if "$CLI" "${CFG[@]}" compile --fqbn "$FQBN" --warnings all \
       --library "$FW/core/ElectroBrightCore" --build-path "$OUT/$name" "$dir" 2>&1 \
       | grep -E "Sketch uses|Global variables|error|warning:" ; then :; fi
  [[ -f "$OUT/$name/$name.ino.bin" ]] || { echo "   FAILED: $name" >&2; status=1; }
done
exit $status
