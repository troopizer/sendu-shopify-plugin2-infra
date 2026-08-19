#!/usr/bin/env bash

logs_since_arg() {
  local epoch="$1"
  local now
  now="$(date +%s)"
  local seconds=$(( now - epoch + 60 ))

  if (( seconds < 60 )); then
    seconds=60
  fi

  printf '%ss' "$seconds"
}

report_log_findings() {
  local log_group="$1"
  local since_epoch="$2"
  local filter_pattern='?ERROR ?Error ?Exception ?FATAL ?Fatal ?WARN ?Warn ?warning ?Warning ?failed ?Failed ?Runtime.ExitError ?timeout ?Timeout'
  local count=""
  local events=""

  count="$(aws logs filter-log-events \
    --log-group-name "$log_group" \
    --start-time "$(( since_epoch * 1000 ))" \
    --filter-pattern "$filter_pattern" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'length(events)' \
    --output text 2>/dev/null || true)"

  if [[ -z "$count" || "$count" == "None" ]]; then
    warn "Could not inspect log group ${log_group}"
    return 0
  fi

  if [[ "$count" == "0" ]]; then
    printf '  No recent warning/error log entries found in %s\n' "$log_group"
    return 0
  fi

  events="$(aws logs filter-log-events \
    --log-group-name "$log_group" \
    --start-time "$(( since_epoch * 1000 ))" \
    --filter-pattern "$filter_pattern" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'events[0:25].[timestamp,logStreamName,message]' \
    --output table 2>/dev/null || true)"

  warn "Recent warning/error log entries found in ${log_group}"
  printf '%s\n' "$events"
}

print_log_stream_tail() {
  local log_group="$1"
  local log_stream="$2"

  aws logs get-log-events \
    --log-group-name "$log_group" \
    --log-stream-name "$log_stream" \
    --limit 30 \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'events[].message' \
    --output text 2>/dev/null || warn "Could not read log stream ${log_group}/${log_stream}"
}

print_log_errors() {
  report_log_findings "$@"
}
