#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Usage:
  scripts/test-lanes.sh mvp0
  scripts/test-lanes.sh extended
  scripts/test-lanes.sh report

Lanes:
  mvp0      Runs default MVP0 scope tests (excludes relay-heavy suites).
  extended  Runs relay-heavy/non-MVP0 suites.
  report    Prints lane composition and rough test-count signal.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

mode="$1"

list_tests() {
  swift test list
}

count_matching_lines() {
  local pattern="$1"
  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' RETURN

  list_tests > "$tmp_file"
  python3 - "$pattern" "$tmp_file" <<'PY'
import re
import sys

pattern = re.compile(sys.argv[1])
path = sys.argv[2]

count = 0
with open(path, "r", encoding="utf-8") as f:
    for line in f:
        if pattern.search(line):
            count += 1

print(count)
PY
}

run_mvp0_lane() {
  swift test --skip "AethosCoreExtendedTests\." --skip "AethosCLITests\.relay"
}

run_extended_lane() {
  swift test --filter "AethosCoreExtendedTests\."
}

report_lane_counts() {
  local total
  local extended
  local mvp0

  total="$(count_matching_lines '^Aethos')"
  extended="$(count_matching_lines '^AethosCoreExtendedTests\.')"

  if [[ "$total" -ge "$extended" ]]; then
    mvp0=$(( total - extended ))
  else
    mvp0=0
  fi

  cat <<EOF
[test-lanes] Soft scope report (non-blocking)
  total discovered tests:      $total
  MVP0 lane estimated tests:   $mvp0
  extended lane tests:         $extended

Commands:
  MVP0 lane:     scripts/test-lanes.sh mvp0
  Extended lane: scripts/test-lanes.sh extended
EOF
}

case "$mode" in
  mvp0)
    run_mvp0_lane
    ;;
  extended)
    run_extended_lane
    ;;
  report)
    report_lane_counts
    ;;
  *)
    usage
    exit 2
    ;;
esac
