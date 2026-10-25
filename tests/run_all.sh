#!/bin/bash
# Kør alle tests fra repo-roden; fejler hvis én fejler.
cd "$(dirname "$0")/.." || exit 1
status=0
for t in tests/test_*.lua; do
    echo "== $t"
    output=$(luajit "$t") || status=1
    echo "$output" | /usr/bin/grep -v '^OK'
done
exit $status
