#!/bin/bash
# Every page, measured, against a settings domain of its own.
#
# Run straight from the installed bundle it stops after the first page
# and hangs: it picks up a real robot address and starts talking to the
# network while the check is spinning the run loop by hand. A throwaway
# bundle id gives it empty settings and nothing to talk to.
set -euo pipefail
cd "$(dirname "$0")"
[ -d build/Rafiq.app ] || ./build.sh >/dev/null
rm -rf /tmp/rafiq-panelcheck.app
cp -R build/Rafiq.app /tmp/rafiq-panelcheck.app
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier in.iotcart.rafiq.panelcheck" \
  /tmp/rafiq-panelcheck.app/Contents/Info.plist
codesign --force --sign - /tmp/rafiq-panelcheck.app 2>/dev/null

# The check furnishes the device itself and puts it in inert mode, so
# the pages draw their full content and nothing reaches the network.

# A page that will not settle hangs AppKit's layout on the main thread,
# where the check itself cannot time it out. So time it out from here,
# and the last page it named is the one that stuck.
/tmp/rafiq-panelcheck.app/Contents/MacOS/Rafiq "${1:---panel-sizes}" &
PID=$!
for _ in $(seq 1 60); do
  kill -0 $PID 2>/dev/null || break
  sleep 1
done
if kill -0 $PID 2>/dev/null; then
  kill $PID 2>/dev/null
  echo
  echo "STUCK: the page named last never finished laying out off screen."
  echo "This is not new and it is not a size failure: the panel declares a"
  echo "hard frame, so the window cannot change size. It means this harness"
  echo "cannot measure that page, and the cause has not been found yet."
  exit 2
fi
wait $PID
