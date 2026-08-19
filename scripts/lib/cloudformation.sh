#!/usr/bin/env bash

CF_CHANGE_SET_NAME=""

stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null 2>&1
}

stack_status() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || true
}

stack_output() {
  local output_key="$1"

  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text 2>/dev/null || true
}

validate_template() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    run_or_print aws cloudformation validate-template \
      --template-body "file://${TEMPLATE_FILE}" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION"
    return
  fi

  run_or_print aws cloudformation validate-template \
    --template-body "file://${TEMPLATE_FILE}" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null
}

build_cf_parameters() {
  CF_PARAMETERS=()

  local parameter_override=""
  local key=""
  local value=""

  for parameter_override in "${PARAMETER_OVERRIDES[@]}"; do
    key="${parameter_override%%=*}"
    value="${parameter_override#*=}"
    CF_PARAMETERS+=("ParameterKey=${key},ParameterValue=${value}")
  done
}

change_set_type() {
  if [[ -n "${CF_CHANGE_SET_TYPE:-}" ]]; then
    printf '%s' "$CF_CHANGE_SET_TYPE"
    return
  fi

  if stack_exists; then
    printf 'UPDATE'
  else
    printf 'CREATE'
  fi
}

create_change_set() {
  CF_CHANGE_SET_NAME="sendu-${ENVIRONMENT_NAME}-$(date +%Y%m%d%H%M%S)"
  build_cf_parameters

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    run_or_print aws cloudformation create-change-set \
      --stack-name "$STACK_NAME" \
      --change-set-name "$CF_CHANGE_SET_NAME" \
      --change-set-type "$(change_set_type)" \
      --template-body "file://${TEMPLATE_FILE}" \
      --parameters "${CF_PARAMETERS[@]}" \
      --capabilities CAPABILITY_NAMED_IAM \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION"
    return
  fi

  run_or_print aws cloudformation create-change-set \
    --stack-name "$STACK_NAME" \
    --change-set-name "$CF_CHANGE_SET_NAME" \
    --change-set-type "$(change_set_type)" \
    --template-body "file://${TEMPLATE_FILE}" \
    --parameters "${CF_PARAMETERS[@]}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null
}

delete_change_set() {
  [[ -n "$CF_CHANGE_SET_NAME" ]] || return

  aws cloudformation delete-change-set \
    --stack-name "$STACK_NAME" \
    --change-set-name "$CF_CHANGE_SET_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null 2>&1 || true
}

is_stack_in_progress_status() {
  case "$1" in
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS|UPDATE_COMPLETE_CLEANUP_IN_PROGRESS|UPDATE_ROLLBACK_IN_PROGRESS|UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS|IMPORT_IN_PROGRESS|IMPORT_ROLLBACK_IN_PROGRESS|REVIEW_IN_PROGRESS)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wait_change_set_ready() {
  local status=""
  local reason=""

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    return
  fi

  while true; do
    status="$(aws cloudformation describe-change-set \
      --stack-name "$STACK_NAME" \
      --change-set-name "$CF_CHANGE_SET_NAME" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query Status \
      --output text)"

    case "$status" in
      CREATE_COMPLETE)
        return
        ;;
      FAILED)
        reason="$(aws cloudformation describe-change-set \
          --stack-name "$STACK_NAME" \
          --change-set-name "$CF_CHANGE_SET_NAME" \
          --profile "$AWS_PROFILE" \
          --region "$AWS_REGION" \
          --query StatusReason \
          --output text)"

        if [[ "$reason" == *"didn't contain changes"* || "$reason" == *"No updates are to be performed"* ]]; then
          printf 'NO_CHANGES\n'
          return
        fi

        die "Change set creation failed: ${reason}"
        ;;
      *)
        sleep 3
        ;;
    esac
  done
}

print_change_set_summary() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    return
  fi

  aws cloudformation describe-change-set \
    --stack-name "$STACK_NAME" \
    --change-set-name "$CF_CHANGE_SET_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'Changes[].ResourceChange.{Action:Action,LogicalResourceId:LogicalResourceId,ResourceType:ResourceType,Replacement:Replacement}' \
    --output table || true
}

execute_change_set() {
  run_or_print aws cloudformation execute-change-set \
    --stack-name "$STACK_NAME" \
    --change-set-name "$CF_CHANGE_SET_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION"
}

is_stack_terminal_status() {
  case "$1" in
    CREATE_COMPLETE|UPDATE_COMPLETE|ROLLBACK_COMPLETE|UPDATE_ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|UPDATE_ROLLBACK_FAILED|DELETE_COMPLETE|DELETE_FAILED)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_stack_success_status() {
  case "$1" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_stack_failure_status() {
  case "$1" in
    CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|UPDATE_ROLLBACK_COMPLETE|UPDATE_ROLLBACK_FAILED|DELETE_FAILED)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wait_stack_operation_started() {
  local previous_status="$1"
  local timeout_seconds="${2:-120}"
  local started_at
  local status=""
  started_at="$(date +%s)"

  while true; do
    status="$(stack_status)"
    [[ -n "$status" && "$status" != "None" ]] || status="UNKNOWN"

    if is_stack_in_progress_status "$status"; then
      printf '  stack operation started: %s\n' "$status"
      return 0
    fi

    if [[ "$status" != "$previous_status" ]] && is_stack_terminal_status "$status"; then
      printf '  stack reached terminal status before watcher start: %s\n' "$status"
      STACK_FINAL_STATUS="$status"
      return 1
    fi

    if (( $(date +%s) - started_at >= timeout_seconds )); then
      die "Stack did not enter an update state after executing change set ${CF_CHANGE_SET_NAME}. Previous status: ${previous_status}. Current status: ${status}."
    fi

    sleep 3
  done
}

check_stack_healthy() {
  local status=""
  status="$(stack_status)"
  [[ -n "$status" && "$status" != "None" ]] || die "Could not resolve CloudFormation stack status for ${STACK_NAME}"

  case "$status" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      printf '  CloudFormation stack status: %s\n' "$status"
      ;;
    *)
      print_recent_stack_events
      die "CloudFormation stack is not healthy: ${status}"
      ;;
  esac
}

wait_stack_terminal() {
  local status=""

  while true; do
    status="$(stack_status)"
    [[ -n "$status" && "$status" != "None" ]] || status="UNKNOWN"
    printf '  stack status: %s\n' "$status"

    if is_stack_terminal_status "$status"; then
      STACK_FINAL_STATUS="$status"
      return
    fi

    sleep 10
  done
}

print_recent_stack_events() {
  aws cloudformation describe-stack-events \
    --stack-name "$STACK_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'StackEvents[0:15].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]' \
    --output table || true
}

watch_cloudformation_events() {
  local seen_file="$1"
  local event_ids=""
  local event_id=""

  while true; do
    event_ids="$(aws cloudformation describe-stack-events \
      --stack-name "$STACK_NAME" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query 'StackEvents[0:10].EventId' \
      --output text 2>/dev/null || true)"

    for event_id in $event_ids; do
      if ! grep -Fxq "$event_id" "$seen_file" 2>/dev/null; then
        aws cloudformation describe-stack-events \
          --stack-name "$STACK_NAME" \
          --profile "$AWS_PROFILE" \
          --region "$AWS_REGION" \
          --query "StackEvents[?EventId=='${event_id}'].[Timestamp,LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
          --output text 2>/dev/null || true
        printf '%s\n' "$event_id" >>"$seen_file"
      fi
    done

    sleep 8
  done
}
