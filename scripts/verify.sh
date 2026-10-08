#!/usr/bin/env bash
# verify.sh — run every present orderer implementation's full suite
# (golden vectors, orderer vectors, integration tests) via its
# scripts/test.sh.
#
#   scripts/verify.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib.sh

IMPLS=$(orderer_present)
[ -n "$IMPLS" ] || { echo "verify: no orderer implementations found"; exit 1; }
for l in $IMPLS; do
  echo "== orderer-$l ($(orderer_dir "$l")) =="
  (cd "$(orderer_dir "$l")" && scripts/test.sh)
done
echo "verify: all present implementations green ($IMPLS)"
