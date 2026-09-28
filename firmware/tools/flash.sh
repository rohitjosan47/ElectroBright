#!/usr/bin/env bash
# Builds one fixture sketch and flashes it to a board over USB with the Arduino
# IDE's own arduino-cli and configuration, then prints the version the board
# reports.
#
#   tools/flash.sh <RGBW|RGB|RGBCCT|CCT|W> [port]
#
# The type is the sketch: every sketch installs the same universal firmware and
# only sets the type a NEW light gets (a light that already has a type keeps it).
# Without [port] the board is found automatically when exactly one USB board is
# connected. The board needs at least 4 MB of flash (two update slots).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FW="$(cd "$HERE/.." && pwd)"
CLI="${ARDUINO_CLI:-/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli}"
CONFIG="${ARDUINO_CONFIG:-$HOME/.arduinoIDE/arduino-cli.yaml}"
FQBN="esp32:esp32:esp32c3:CDCOnBoot=cdc"

usage() { echo "usage: tools/flash.sh <RGBW|RGB|RGBCCT|CCT|W> [port]" >&2; exit 2; }
[[ $# -ge 1 && $# -le 2 ]] || usage
TYPE="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
case "$TYPE" in RGBW|RGB|RGBCCT|CCT|W) ;; *) usage ;; esac
SKETCH="$FW/fixtures/ElectroBright_$TYPE"
PORT="${2:-}"

[[ -x "$CLI" ]] || CLI="$(command -v arduino-cli || true)"
[[ -n "$CLI" ]] || { echo "arduino-cli not found (install the Arduino IDE or set ARDUINO_CLI)" >&2; exit 1; }
CFG=()
[[ -f "$CONFIG" ]] && CFG=(--config-file "$CONFIG")

# ---- 1. The board --------------------------------------------------------------------
if [[ -z "$PORT" ]]; then
  PORTS="$("$CLI" "${CFG[@]}" board list --format json | python3 -c '
import json, sys
ports = [p["port"] for p in json.load(sys.stdin).get("detected_ports", [])]
# USB boards only (Bluetooth and debug ports have no USB vendor id).
for p in ports:
    if p.get("protocol") == "serial" and p.get("properties", {}).get("vid"):
        print(p["address"])
')"
  COUNT="$(printf '%s' "$PORTS" | grep -c . || true)"
  if [[ "$COUNT" -eq 0 ]]; then
    echo "No USB board found. Connect the ESP32-C3 (a data cable), or name the port: tools/flash.sh $TYPE <port>" >&2
    exit 1
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "More than one USB board is connected; name the port: tools/flash.sh $TYPE <port>" >&2
    printf '  %s\n' $PORTS >&2
    exit 1
  fi
  PORT="$PORTS"
fi
echo "== board on $PORT"

# The partition table has two 1.25 MB update slots: 4 MB of flash at least.
ESPTOOL="$(ls -d "$HOME"/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool \
                  "$HOME"/.arduino15/packages/esp32/tools/esptool_py/*/esptool 2>/dev/null | tail -1 || true)"
[[ -n "$ESPTOOL" ]] || ESPTOOL="$(command -v esptool || command -v esptool.py || true)"
[[ -n "$ESPTOOL" ]] || { echo "esptool not found (install the esp32 board package in the Arduino IDE)" >&2; exit 1; }
ID="$("$ESPTOOL" --port "$PORT" flash-id 2>&1)" || { echo "$ID" >&2; echo "Could not read the board's flash ($PORT)." >&2; exit 1; }
MB="$(printf '%s\n' "$ID" | sed -n 's/.*Detected flash size: *\([0-9]*\)MB.*/\1/p' | head -1)"
if [[ -z "$MB" ]]; then
  echo "$ID" >&2
  echo "Could not tell the board's flash size." >&2
  exit 1
fi
if [[ "$MB" -lt 4 ]]; then
  echo "This board has ${MB} MB of flash. ElectroBright needs at least 4 MB (two 1.25 MB firmware slots for wireless updates). Use an ESP32-C3 board with 4 MB of flash." >&2
  exit 1
fi
echo "   flash ${MB} MB"

# ---- 2. Build ----------------------------------------------------------------------------
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
echo "== build ElectroBright_$TYPE"
"$CLI" "${CFG[@]}" compile --fqbn "$FQBN" --warnings all \
  --library "$FW/core/ElectroBrightCore" --build-path "$BUILD" "$SKETCH" 2>&1 \
  | grep -E "Sketch uses|Global variables|error|warning:" || true
[[ -f "$BUILD/ElectroBright_$TYPE.ino.bin" ]] || { echo "build failed" >&2; exit 1; }

# ---- 3. Upload ---------------------------------------------------------------------------
echo "== upload"
"$CLI" "${CFG[@]}" upload --fqbn "$FQBN" -p "$PORT" --input-dir "$BUILD" "$SKETCH"

# ---- 4. What the board reports -------------------------------------------------------------
echo "== board reports"
python3 - "$PORT" <<'PY'
import os, select, sys, termios, time

port = sys.argv[1]
deadline = time.time() + 20
while time.time() < deadline:
    try:
        fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except OSError:
        time.sleep(0.5)  # the USB port comes back after the reset
        continue
    try:
        attrs = termios.tcgetattr(fd)
        attrs[0] = attrs[1] = attrs[3] = 0          # raw: no input/output processing, no echo
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = termios.B115200
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
        buf = b""
        for _ in range(10):
            os.write(fd, b"VERSION\n")
            end = time.time() + 1.0
            while time.time() < end:
                r, _, _ = select.select([fd], [], [], 0.1)
                if r:
                    try:
                        buf += os.read(fd, 256)
                    except OSError:
                        break
                for line in buf.split(b"\n"):
                    if line.startswith(b"VERSION:"):
                        print("   " + line.decode(errors="replace").strip())
                        sys.exit(0)
    except OSError:
        pass
    finally:
        os.close(fd)
    time.sleep(0.5)
sys.exit("   the board did not report a version (is it running? try unplugging it once)")
PY
