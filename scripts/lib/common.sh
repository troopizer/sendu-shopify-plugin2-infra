#!/usr/bin/env bash

log() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'WARN: %s\n' "$1" >&2
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

quote_args() {
  local quoted=()
  local arg

  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done

  printf '%s' "${quoted[*]}"
}

run_or_print() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    printf '+ %s\n' "$(quote_args "$@")"
    return 0
  fi

  "$@"
}
