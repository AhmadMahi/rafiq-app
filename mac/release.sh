#!/bin/bash
# Build and publish, with the tag worked out rather than typed.
#
# The app's updater only looks at releases tagged mac-v, so that it can
# never be handed the Windows build. Two releases went out tagged with
# a bare version number instead, and the updater could not see either
# of them: it reported "up to date" while sitting two versions behind,
# which is the worst way for this to fail because it looks like
# nothing is wrong. The tag comes from the version in build.sh now and
# nobody gets to type it.
set -euo pipefail
cd "$(dirname "$0")"

VER=$(sed -n 's/^VER="\(.*\)"$/\1/p' build.sh)
[ -n "$VER" ] || { echo "cannot read VER out of build.sh"; exit 1; }
PREFIX=$(sed -n 's/.*tagPrefix = "\(.*\)"/\1/p' Sources/Updater.swift)
[ -n "$PREFIX" ] || { echo "cannot read tagPrefix out of Updater.swift"; exit 1; }
TAG="$PREFIX$VER"
DMG="build/Rafiq-$VER.dmg"

[ -f "$DMG" ] || ./build.sh >/dev/null
[ -f "$DMG" ] || { echo "no $DMG after building"; exit 1; }

echo "publishing $DMG as $TAG"
gh release create "$TAG" "$DMG" --title "Rafiq $VER" --notes-file "${1:-/dev/stdin}"

# And check the thing that actually matters: that the app, following
# its own rules, can now see it.
sleep 3
SEEN=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/AhmadMahi/rafiq-app/releases?per_page=30" \
  | /usr/bin/python3 -c "
import json,sys
p='$PREFIX'
best=None
for r in json.load(sys.stdin):
    t=r.get('tag_name','')
    if not t.startswith(p) or r.get('draft'): continue
    if not any(a['name'].endswith('.dmg') for a in r.get('assets',[])): continue
    v=[int(x) if x.isdigit() else 0 for x in t[len(p):].split('.')]
    if best is None or v>best[0]: best=(v,t[len(p):])
print(best[1] if best else 'NOTHING')
")
echo "the updater now sees: $SEEN"
[ "$SEEN" = "$VER" ] || { echo "FAIL: it should have seen $VER"; exit 1; }
