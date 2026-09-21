#!/usr/bin/env bash
# Runs the whole stock account scenario suite against the vnet named in the manifest.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

rm -f .state/run-id
echo '{"setup":{},"checks":[]}' >results.json

./prepare.sh || { echo "prepare failed, nothing to run" >&2; exit 1; }

CRASHED=0
for scenario in 0*.sh; do
  echo
  echo "== $scenario"
  ./"$scenario" && continue
  # A scenario that died before recording the failure leaves the tally green otherwise.
  jq -e --arg s "${scenario%.sh}" 'any(.checks[]; .scenario == $s and (.pass | not))' results.json >/dev/null ||
    { echo "$scenario exited non-zero without recording a failed check" >&2; CRASHED=$((CRASHED + 1)); }
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
echo "$((TOTAL - FAILED))/$TOTAL checks passed, $CRASHED scenario(s) died"
exit $((FAILED + CRASHED))
