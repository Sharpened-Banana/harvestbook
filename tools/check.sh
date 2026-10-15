#!/usr/bin/env bash
# Syntax-checks addon sources, verifies TOC entries exist, runs the test suite.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
fail=0

echo "== syntax (luajit -bl)"
while IFS= read -r f; do
  if ! luajit -bl "$f" >/dev/null; then
    echo "SYNTAX ERROR: $f"
    fail=1
  fi
done < <(find Harvestbook/Core Harvestbook/Logic Harvestbook/UI Harvestbook/Modules -name '*.lua' 2>/dev/null | sort)

echo "== TOC entries"
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in ''|\#*) continue ;; esac
  path="Harvestbook/$(printf '%s' "$line" | tr '\\' '/')"
  if [ ! -f "$path" ]; then
    echo "MISSING TOC ENTRY: $line"
    fail=1
  fi
done < Harvestbook/Harvestbook.toc

echo "== tests"
luajit tests/run.lua || fail=1

exit $fail
