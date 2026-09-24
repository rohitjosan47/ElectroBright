#!/usr/bin/env bash
# ElectroBright app verification gate (plan §14). Every milestone must pass it.
#
#   tool/check.sh            format, analyze, firmware host tests, flutter test
#   tool/check.sh --builds   ...plus iOS simulator and signed Android release builds
set -euo pipefail

APP="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP/.." && pwd)"
BUILDS=0
for arg in "$@"; do
  case "$arg" in
    --builds) BUILDS=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
cd "$APP"

step "dart format (hand-written sources)"
# Generated code (Pigeon *.g.dart, gen-l10n) is excluded; it is regenerated, not edited.
find lib test integration_test tool -name '*.dart' ! -name '*.g.dart' \
  ! -path 'lib/l10n/app_localizations*' -print0 |
  xargs -0 dart format --output=none --set-exit-if-changed

step "flutter analyze"
flutter analyze --no-pub

step "firmware host tests (portable core + fwsim)"
make -C "$ROOT/firmware/test" --no-print-directory

step "flutter test"
flutter test --no-pub

if [[ "$BUILDS" == 1 ]]; then
  # No --no-pub here: each build must regenerate the plugin registrants for its
  # own mode (release excludes dev-only plugins such as integration_test).
  step "iOS simulator build"
  flutter build ios --simulator --debug
  step "Android release build (signed with the upgrade key)"
  flutter build apk --release
fi

printf '\n\033[1;32mAll checks passed.\033[0m\n'
