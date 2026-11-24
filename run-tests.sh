#!/bin/zsh
# Builds and runs the sync engine tests in a temporary folder. Never touches real drives or the real Trash.
set -euo pipefail
cd "${0:A:h}"
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"; trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
rc=0
for suite in Engine Compare Model; do
  extra=(); [[ $suite == Model ]] && extra=(ProjectDriveSync/{Comparison,UpdateChecker}.swift)
  xcrun swiftc -swift-version 5 -default-isolation MainActor -O -suppress-warnings \
    ProjectDriveSync/{Models,Compare,SyncEngine}.swift $extra Tests/$suite/main.swift -o "$WORK/$suite"
  "$WORK/$suite" "$WORK/run-$suite" > "$WORK/$suite.txt" || rc=1
  echo "$suite: $(grep -c '  PASS' "$WORK/$suite.txt" || true) passed, $(grep -c '  FAIL' "$WORK/$suite.txt" || true) failed"
  grep -E "^==|  FAIL" "$WORK/$suite.txt" | grep -B1 "  FAIL" || true
  tail -1 "$WORK/$suite.txt"
done
exit $rc
