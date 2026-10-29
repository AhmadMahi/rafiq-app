#!/usr/bin/env bash
# Every check for the Mac app, in one go. The link suite re-extracts the
# shipped bodies first, so it can never quietly drift away from the code
# it is testing.
#
#   ./tests/run.sh            the headless checks, which is what CI runs
#   ./tests/run.sh --panels   those, and then measure every settings page
#
# --panels builds the app and drives AppKit off screen, so it needs a
# window server and a minute or two. It is left out of the default run
# for that reason, not because it matters less.
set -u
cd "$(dirname "$0")/.."          # mac/
panels=0
[ "${1:-}" = "--panels" ] && panels=1
fail=0
run() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; shift; "$@" || fail=1; }

# The find/attach/resweep bodies come straight out of Sources/RobotLink.swift
# and are spliced into a harness that fakes CoreBluetooth around them.
run "app: finding the watch" bash -c '
  set -e
  python3 tests/extract.py Sources/RobotLink.swift tests/linktest/real.swift.inc
  rm -rf tests/linktest/run && mkdir -p tests/linktest/run
  python3 -c "
import io
io.open(\"tests/linktest/run/main.swift\",\"w\").write(
  io.open(\"tests/linktest/harness.swift\").read().replace(\"#include_real_bodies\",
  io.open(\"tests/linktest/real.swift.inc\").read()))"
  cd tests/linktest/run && swiftc -o t1 main.swift && ./t1'

run "app: every row fits its panel" python3 rowcheck.py

if [ $panels = 1 ]; then
  run "app: every page measured against its panel" ./panelcheck.sh
else
  printf '\n\033[1m== app: every page measured against its panel ==\033[0m\n'
  printf '  skipped: needs a window server. Run mac/tests/run.sh --panels for it.\n'
fi

if [ $fail = 0 ]; then printf '\n\033[1mALL SUITES PASSED\033[0m\n\n'
else printf '\n\033[1mSOMETHING FAILED\033[0m\n\n'; fi
exit $fail
