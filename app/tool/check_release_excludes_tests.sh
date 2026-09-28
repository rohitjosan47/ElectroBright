#!/usr/bin/env bash
# Checks that a release build contains neither the rollback test images nor
# the option to install them (they exist in debug builds only; see
# lib/features/developer/rollback_test.dart).
#
#   tool/check_release_excludes_tests.sh build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail

APK="${1:?usage: $0 <release apk>}"
LIB="$(mktemp)"
trap 'rm -f "$LIB"' EXIT
unzip -p "$APK" lib/arm64-v8a/libapp.so > "$LIB"
[[ -s "$LIB" ]] || { echo "no lib/arm64-v8a/libapp.so in $APK" >&2; exit 1; }

# Control: strings the release app does use are found this way.
grep -a -q "Update firmware" "$LIB" || { echo "scan broken: 'Update firmware' not found" >&2; exit 1; }

found=0
for marker in "ElectroBright_RollbackTest" "Install rollback test image" "dev-rollback-test" "rollback-fails-check"; do
  if grep -a -q "$marker" "$LIB"; then
    echo "release build contains '$marker'" >&2
    found=1
  fi
done
[[ "$found" == 0 ]] || exit 1
echo "release build: no rollback test images or option ($(wc -c < "$LIB" | tr -d ' ') bytes of Dart code)"
