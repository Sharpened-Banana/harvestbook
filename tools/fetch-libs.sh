#!/usr/bin/env bash
# Vendors third-party libraries into Harvestbook/libs/. Re-run to refresh.
#
# Sources (verified 2026-10-15):
#   Ace3             https://github.com/WoWUIDev/Ace3                  tag Release-r1403
#   HereBeDragons    https://github.com/Nevcairiel/HereBeDragons       tag 2.18-release (no bare "2.18" tag exists)
#   LibDataBroker    https://github.com/tekkub/libdatabroker-1-1       tag v1.1.4 (HEAD)
#   LibDBIcon-1.0    https://repos.wowace.com/wow/libdbicon-1-0/trunk  (official SVN, linked from
#                    https://www.wowace.com/projects/libdbicon-1-0/source; no maintained GitHub repo
#                    exists, mirrors are stale). Fetched over HTTP, revision 166, MINOR 57.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBS="$ROOT/Harvestbook/libs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$LIBS"

echo "== Ace3"
git clone -q -c advice.detachedHead=false --depth 1 --branch Release-r1403 https://github.com/WoWUIDev/Ace3 "$TMP/Ace3"
for lib in LibStub CallbackHandler-1.0 AceAddon-3.0 AceDB-3.0 AceDBOptions-3.0 AceEvent-3.0 \
           AceConsole-3.0 AceConfig-3.0 AceGUI-3.0 AceSerializer-3.0 AceTimer-3.0; do
  rm -rf "$LIBS/$lib"
  cp -R "$TMP/Ace3/$lib" "$LIBS/$lib"
done

echo "== HereBeDragons"
git clone -q -c advice.detachedHead=false --depth 1 --branch 2.18-release https://github.com/Nevcairiel/HereBeDragons "$TMP/HBD"
mkdir -p "$LIBS/HereBeDragons"
cp "$TMP/HBD/HereBeDragons-2.0.lua" "$TMP/HBD/HereBeDragons-Pins-2.0.lua" "$LIBS/HereBeDragons/"

echo "== LibDataBroker-1.1"
git clone -q -c advice.detachedHead=false --depth 1 --branch v1.1.4 https://github.com/tekkub/libdatabroker-1-1 "$TMP/LDB"
mkdir -p "$LIBS/LibDataBroker-1.1"
cp "$TMP/LDB/LibDataBroker-1.1.lua" "$LIBS/LibDataBroker-1.1/"

echo "== LibDBIcon-1.0"
SVN=https://repos.wowace.com/wow/libdbicon-1-0/trunk/LibDBIcon-1.0
mkdir -p "$LIBS/LibDBIcon-1.0"
curl -fsSL "$SVN/LibDBIcon-1.0.lua" -o "$LIBS/LibDBIcon-1.0/LibDBIcon-1.0.lua"
curl -fsSL "$SVN/lib.xml" -o "$LIBS/LibDBIcon-1.0/lib.xml"

find "$LIBS" -name .git -prune -exec rm -rf {} +
echo "done"
