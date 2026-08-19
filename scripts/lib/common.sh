#!/usr/bin/env bash

if [[ -z "${NO_COLOR:-}" && -z "${PLAIN_OUTPUT:-}" && -t 1 ]]; then
  COLOR_BLUE=$'\033[0;34m'
  COLOR_GREEN=$'\033[0;32m'
  COLOR_YELLOW=$'\033[0;33m'
  COLOR_RED=$'\033[0;31m'
  COLOR_CYAN=$'\033[0;36m'
  COLOR_BOLD=$'\033[1m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_BLUE=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_CYAN=''
  COLOR_BOLD=''
  COLOR_RESET=''
fi

if [[ -n "${PLAIN_OUTPUT:-}" ]]; then
  ICON_PHASE='>'
  ICON_INFO='i'
  ICON_OK='OK'
  ICON_WARN='WARN'
  ICON_FAIL='FAIL'
  ICON_WAIT='...'
  ICON_ARROW='->'
else
  ICON_PHASE='◆'
  ICON_INFO='ℹ'
  ICON_OK='✓'
  ICON_WARN='⚠'
  ICON_FAIL='✗'
  ICON_WAIT='⏱'
  ICON_ARROW='→'
fi

DEPLOY_PHASE_NUMBER="${DEPLOY_PHASE_NUMBER:-0}"
DEPLOY_PHASE_TOTAL="${DEPLOY_PHASE_TOTAL:-7}"
DEPLOY_PHASE_STARTED_AT="${DEPLOY_PHASE_STARTED_AT:-}"

format_duration() {
  local seconds="$1"
  printf '%02dm %02ds' "$((seconds / 60))" "$((seconds % 60))"
}

phase() {
  local message="$1"
  DEPLOY_PHASE_NUMBER=$((DEPLOY_PHASE_NUMBER + 1))
  DEPLOY_PHASE_STARTED_AT="$(date +%s)"
  printf '\n%s%s [%d/%d] %s%s\n' \
    "$COLOR_BLUE" "$ICON_PHASE" "$DEPLOY_PHASE_NUMBER" "$DEPLOY_PHASE_TOTAL" "$message" "$COLOR_RESET"
}

phase_complete() {
  local message="$1"
  local now elapsed
  now="$(date +%s)"
  elapsed=0
  if [[ -n "$DEPLOY_PHASE_STARTED_AT" ]]; then
    elapsed=$((now - DEPLOY_PHASE_STARTED_AT))
  fi
  printf '%s%s %s%s  (%s)\n' \
    "$COLOR_GREEN" "$ICON_OK" "$message" "$COLOR_RESET" "$(format_duration "$elapsed")"
}

phase_note() {
  printf '  %s%s %s%s\n' "$COLOR_CYAN" "$ICON_ARROW" "$1" "$COLOR_RESET"
}

print_kv_table() {
  local key value display_value
  printf '%s┌──────────────────────┬─────────────────────────────────────────────────────────────┐%s\n' "$COLOR_BOLD" "$COLOR_RESET"
  printf '%s│ %-20s │ %-59s │%s\n' "$COLOR_BOLD" 'Field' 'Value' "$COLOR_RESET"
  printf '%s├──────────────────────┼─────────────────────────────────────────────────────────────┤%s\n' "$COLOR_BOLD" "$COLOR_RESET"
  while [[ $# -gt 1 ]]; do
    key="$1"
    value="$2"
    shift 2
    if (( ${#value} > 59 )); then
      display_value="${value:0:56}..."
    else
      display_value="$value"
    fi
    printf '│ %-20s │ %-59s │\n' "${key:0:20}" "$display_value"
  done
  printf '%s└──────────────────────┴─────────────────────────────────────────────────────────────┘%s\n' "$COLOR_BOLD" "$COLOR_RESET"
}

log() {
  printf '%s%s %s%s\n' "$COLOR_BLUE" "$ICON_PHASE" "$1" "$COLOR_RESET"
}

warn() {
  printf '%s%s %s%s\n' "$COLOR_YELLOW" "$ICON_WARN" "$1" "$COLOR_RESET" >&2
}

die() {
  printf '%s%s %s%s\n' "$COLOR_RED" "$ICON_FAIL" "$1" "$COLOR_RESET" >&2
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
