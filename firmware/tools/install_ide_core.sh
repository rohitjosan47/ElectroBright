#!/usr/bin/env bash
# Makes the shared firmware core (firmware/core/ElectroBrightCore) visible to the
# Arduino IDE by linking it into the sketchbook's libraries folder. Run once,
# then restart the Arduino IDE.
#
#   tools/install_ide_core.sh           symlink (recommended: always up to date)
#   tools/install_ide_core.sh --copy    copy instead (re-run after every core change;
#                                       tools/build.sh warns when the copy is stale)
#   tools/install_ide_core.sh --status  show what is installed
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$(cd "$HERE/../core/ElectroBrightCore" && pwd)"
CLI_CONFIG="$HOME/.arduinoIDE/arduino-cli.yaml"

sketchbook() {
  if [[ -f "$CLI_CONFIG" ]]; then
    local user
    user="$(awk '/^directories:/{d=1;next} d&&/^[^ ]/{d=0} d&&$1=="user:"{print $2}' "$CLI_CONFIG")"
    [[ -n "$user" ]] && { echo "$user"; return; }
  fi
  echo "$HOME/Documents/Arduino"
}

DEST="$(sketchbook)/libraries/ElectroBrightCore"
MODE="${1:-}"

case "$MODE" in
  --status)
    if [[ -L "$DEST" ]]; then echo "symlink: $DEST -> $(readlink "$DEST")"
    elif [[ -d "$DEST" ]]; then
      if diff -rq "$CORE" "$DEST" >/dev/null; then echo "copy (up to date): $DEST"
      else echo "copy (STALE, re-run with --copy): $DEST"; fi
    else echo "not installed ($DEST)"; fi
    exit 0 ;;
  ""|--copy) ;;
  *) echo "usage: $0 [--copy|--status]" >&2; exit 2 ;;
esac

mkdir -p "$(dirname "$DEST")"
if [[ -L "$DEST" ]]; then
  rm "$DEST"
elif [[ -e "$DEST" ]]; then
  # Only ever replace a previous install of this library.
  if [[ ! -f "$DEST/library.properties" ]] || ! grep -q '^name=ElectroBrightCore$' "$DEST/library.properties"; then
    echo "refusing to replace $DEST: it is not an ElectroBrightCore install" >&2
    exit 1
  fi
  rm -rf "$DEST"
fi

if [[ "$MODE" == "--copy" ]]; then
  cp -R "$CORE" "$DEST"
  echo "copied core to $DEST"
else
  ln -s "$CORE" "$DEST"
  echo "linked $DEST -> $CORE"
fi
echo "Restart the Arduino IDE, then open a sketch in firmware/fixtures/<Fixture>/."
