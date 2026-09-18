#!/usr/bin/env bash
# Runs the whole stock account scenario suite against the vnet named in the manifest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

rm -f .state/run-id
echo '{"setup":{},"checks":[]}' >results.json

./prepare.sh || { echo "prepare failed, nothing to run" >&2; exit 1; }

for scenario in 0*.sh; do
  echo
  echo "== $scenario"
  ./"$scenario" || true
done

echo
printf '%-5s %-15s %-52s %s\n' STATUS SCENARIO CHECK VALUE
jq -r '.checks[] | [(if .pass then "ok" else "FAIL" end), .scenario, .check, .value] | @tsv' results.json |
  while IFS=$'\t' read -r status scenario check value; do
    printf '%-5s %-15s %-52s %s\n' "$status" "$scenario" "$check" "$value"
  done

FAILED=$(jq '[.checks[] | select(.pass | not)] | length' results.json)
TOTAL=$(jq '.checks | length' results.json)
echo
echo "$((TOTAL - FAILED))/$TOTAL checks passed"
exit "$FAILED"
