#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_STARTED_AT="$(date +%s)"
DEPLOY_PHASE_TOTAL=8
PLAN_ONLY=false
DRY_RUN=false
CF_CHANGE_SET_TYPE=UPDATE
SKIP_HTTP=false
WATCH_TMP_DIR=""
WATCHERS_STARTED=false
WATCHER_PIDS=""

# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/cloudformation.sh
. "${SCRIPT_DIR}/lib/cloudformation.sh"
# shellcheck source=scripts/lib/ecr.sh
. "${SCRIPT_DIR}/lib/ecr.sh"
# shellcheck source=scripts/lib/logs.sh
. "${SCRIPT_DIR}/lib/logs.sh"
# shellcheck source=scripts/lib/ecs.sh
. "${SCRIPT_DIR}/lib/ecs.sh"
# shellcheck source=scripts/lib/lambda.sh
. "${SCRIPT_DIR}/lib/lambda.sh"
# shellcheck source=scripts/lib/health.sh
. "${SCRIPT_DIR}/lib/health.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy.sh [options]

Options:
  --environment <name>                Environment folder/name: staging or prod
  --environment-dir <path>            Environment folder
  --profile <aws-profile>             AWS profile
  --region <aws-region>               AWS region
  --stack-name <stack-name>           CloudFormation stack name
  --template-file <path>              CloudFormation template YAML
  --parameters-file <path>            Parameter JSON
  --version <tag>                     Image tag for backend and frontend
  --backend-image-tag <tag>           Backend image tag
  --frontend-image-tag <tag>          Frontend image tag
  --plan                              Create and print a change set without executing it
  --dry-run                           Print AWS commands without executing them
  --skip-http                         Skip frontend/backend HTTP health checks
  -h, --help                          Show this help
EOF
}

cleanup_watchers() {
  local pid
  [[ "$WATCHERS_STARTED" == "true" ]] || return 0

  for pid in ${WATCHER_PIDS:-}; do
    kill "$pid" >/dev/null 2>&1 || true
  done

  if [[ -n "$WATCH_TMP_DIR" ]]; then
    rm -rf "$WATCH_TMP_DIR"
    WATCH_TMP_DIR=""
  fi

  WATCHERS_STARTED=false
}

start_watchers() {
  WATCH_TMP_DIR="$(mktemp -d)"
  : >"${WATCH_TMP_DIR}/cf-events.seen"
  : >"${WATCH_TMP_DIR}/stopped-tasks.seen"

  watch_cloudformation_events "${WATCH_TMP_DIR}/cf-events.seen" &
  WATCHER_PIDS="${WATCHER_PIDS:-} $!"

  watch_ecs_rollout "$DEPLOY_STARTED_AT" "${WATCH_TMP_DIR}/stopped-tasks.seen" &
  WATCHER_PIDS="${WATCHER_PIDS:-} $!"

  WATCHERS_STARTED=true
}

run_post_deploy_checks() {
  local frontend_runtime
  frontend_runtime="$(get_parameter_override EnableFrontendRuntime)"

  log "Waiting for ECS service stability"
  wait_ecs_stable

  log "Checking ALB target health"
  check_alb_target_health

  if [[ "$frontend_runtime" != "false" ]]; then
    log "Checking Lambda status"
    check_lambda_status
  fi

  if [[ "$SKIP_HTTP" != "true" ]]; then
    log "Running HTTP health checks"
    check_backend_health
    if [[ "$frontend_runtime" != "false" ]]; then
      check_frontend_health
    fi
  fi

  log "Checking recent backend errors"
  report_log_findings "$(backend_log_group)" "$DEPLOY_STARTED_AT"

  if [[ "$frontend_runtime" != "false" ]]; then
    log "Checking recent Lambda errors"
    print_lambda_errors "$DEPLOY_STARTED_AT"
  fi
}

assert_stack_ready_for_deploy() {
  local status=""

  status="$(stack_status)"
  [[ -n "$status" && "$status" != "None" ]] || die "Could not resolve CloudFormation stack status for ${STACK_NAME}"

  if ! is_stack_terminal_status "$status"; then
    die "CloudFormation stack '${STACK_NAME}' is not in a terminal state: ${status}. Wait for the current operation to finish before deploying."
  fi

  printf '  CloudFormation stack status: %s\n' "$status"
}

init_config_defaults
load_env_file "$@"

while [[ $# -gt 0 ]]; do
  if parse_common_arg "$@"; then
    shift "$PARSE_COMMON_CONSUMED"
    continue
  fi

  case "$1" in
    --plan)
      PLAN_ONLY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-http)
      SKIP_HTTP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

trap cleanup_watchers EXIT

require_cmd aws
require_cmd jq

phase "Resolve deployment configuration"
resolve_deploy_config
resolve_missing_image_tags
load_parameter_overrides
set_parameter_override BackendImageTag "$BACKEND_IMAGE_TAG"
set_parameter_override FrontendImageTag "$FRONTEND_IMAGE_TAG"
set_parameter_override EnableFrontendRuntime true
phase_complete "Deployment configuration resolved"

phase "Display deployment configuration"
print_kv_table \
  "Profile" "$AWS_PROFILE" \
  "Region" "$AWS_REGION" \
  "Environment" "$ENVIRONMENT_NAME" \
  "Stack" "$STACK_NAME" \
  "Template" "$TEMPLATE_FILE" \
  "Parameters" "$PARAMETERS_FILE" \
  "Backend image" "$BACKEND_IMAGE_TAG" \
  "Frontend image" "$FRONTEND_IMAGE_TAG" \
  "Plan only" "$PLAN_ONLY" \
  "Dry run" "$DRY_RUN"
phase_complete "Deployment configuration displayed"

phase "Validate CloudFormation template"
validate_template
phase_complete "CloudFormation template validated"

phase "Check stack state and shared ECR images"
if [[ "$DRY_RUN" != "true" ]]; then
  stack_exists || die "CloudFormation stack '${STACK_NAME}' does not exist. Run './scripts/bootstrap.sh --environment ${ENVIRONMENT_NAME}' first."
  phase_note "Checking CloudFormation stack state"
  assert_stack_ready_for_deploy
  phase_note "Checking shared ECR image tags"
  assert_required_ecr_images_exist "$(get_parameter_override EnableFrontendRuntime)"
  print_ecr_summary
else
  phase_note "Skipped AWS state checks in dry-run mode"
fi
phase_complete "Stack and shared ECR checks complete"

phase "Create CloudFormation change set"
create_change_set
phase_complete "CloudFormation change set created"

if [[ "$DRY_RUN" == "true" ]]; then
  phase_note "Dry run complete; change set was not executed"
  exit 0
fi

change_set_result="$(wait_change_set_ready)"
if [[ "$change_set_result" == "NO_CHANGES" ]]; then
  log "No stack changes to apply"
  delete_change_set
  if [[ "$PLAN_ONLY" != "true" ]]; then
    run_post_deploy_checks
  fi
  exit 0
fi

print_change_set_summary

if [[ "$PLAN_ONLY" == "true" ]]; then
  log "Plan complete; change set was not executed"
  delete_change_set
  exit 0
fi

phase "Execute CloudFormation change set"
phase_note "Applying infrastructure changes"
previous_stack_status="$(stack_status)"
execute_change_set

if ! wait_stack_operation_started "$previous_stack_status"; then
  if ! is_stack_success_status "${STACK_FINAL_STATUS:-}"; then
    print_recent_stack_events
    print_recent_stopped_tasks "$DEPLOY_STARTED_AT"
    report_log_findings "$(backend_log_group)" "$DEPLOY_STARTED_AT"
    die "Deployment failed with stack status ${STACK_FINAL_STATUS}"
  fi
fi
phase_complete "CloudFormation change set executed"

phase "Monitor CloudFormation and ECS"
phase_note "Watching CloudFormation events and ECS rollout"
start_watchers
wait_stack_terminal
cleanup_watchers
phase_complete "CloudFormation and ECS monitoring complete"

if ! is_stack_success_status "$STACK_FINAL_STATUS"; then
  print_recent_stack_events
  print_recent_stopped_tasks "$DEPLOY_STARTED_AT"
  report_log_findings "$(backend_log_group)" "$DEPLOY_STARTED_AT"
  die "Deployment failed with stack status ${STACK_FINAL_STATUS}"
fi

phase "Run post-deployment health checks"
run_post_deploy_checks
phase_complete "Post-deployment health checks passed"

elapsed=$(( $(date +%s) - DEPLOY_STARTED_AT ))
printf '\n%s%s Deployment successful%s\n' "$COLOR_GREEN" "$ICON_OK" "$COLOR_RESET"
print_kv_table \
  "Environment" "$ENVIRONMENT_NAME" \
  "Stack" "$STACK_NAME" \
  "Backend image" "$BACKEND_IMAGE_TAG" \
  "Frontend image" "$FRONTEND_IMAGE_TAG" \
  "Duration" "$(format_duration "$elapsed")" \
  "Status" "SUCCESS"
