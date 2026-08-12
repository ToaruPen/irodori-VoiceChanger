#!/usr/bin/env bash
set -euo pipefail

swift test --enable-code-coverage

test_binary=$(find .build -path '*/debug/*.xctest/Contents/MacOS/*PackageTests' -type f -print | head -n 1)
profile=$(find .build -path '*/debug/codecov/default.profdata' -type f -print | head -n 1)

if [[ -z "$test_binary" || -z "$profile" ]]; then
  echo "coverage artifacts are missing" >&2
  exit 1
fi

report=$(xcrun llvm-cov report "$test_binary" \
  -instr-profile "$profile" \
  -ignore-filename-regex='Tests/|PackageTests\.derived/|Sources/IrodoriVoiceChangerMacOS/|Sources/IrodoriVoiceChangerCLI/|Package.swift')
printf '%s\n' "$report"

line_coverage=$(printf '%s\n' "$report" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')
if [[ -z "$line_coverage" ]]; then
  echo "unable to parse total line coverage" >&2
  exit 1
fi

awk -v coverage="$line_coverage" 'BEGIN {
  if (coverage + 0 < 90) {
    printf "core line coverage %.2f%% is below 90%%\n", coverage > "/dev/stderr"
    exit 1
  }
}'
