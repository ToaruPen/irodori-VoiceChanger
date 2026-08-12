#!/usr/bin/env bash
set -euo pipefail

public_run=$(just --dry-run run 2>&1)
internal_run=$(just --dry-run _cli run 2>&1)
if ! grep -Eq 'just _cli run([[:space:]]|$)' <<<"$public_run" \
  || ! grep -Eq 'irodori-voicechanger run([[:space:]]|$)' <<<"$internal_run"; then
  echo "just run must dispatch the CLI run command" >&2
  exit 1
fi
