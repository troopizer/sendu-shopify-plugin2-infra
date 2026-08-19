#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_STARTED_AT="$(date +%s)"
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
  [[ "$WATCHERS_STARTED" == "true" ]] || return

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

init_config_defaults
load_env_file

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
resolve_deploy_config
require_image_tags
load_parameter_overrides
set_parameter_override BackendImageTag "$BACKEND_IMAGE_TAG"
set_parameter_override FrontendImageTag "$FRONTEND_IMAGE_TAG"
set_parameter_override EnableFrontendRuntime true
set_parameter_override BackendDesiredCount 1

log "Resolved deploy values"
print_resolved_config
printf '  plan only: %s\n' "$PLAN_ONLY"
printf '  dry run: %s\n' "$DRY_RUN"

log "Validating CloudFormation template"
validate_template

if [[ "$DRY_RUN" != "true" ]]; then
  stack_exists || die "CloudFormation stack '${STACK_NAME}' does not exist. Run './scripts/bootstrap.sh --environment ${ENVIRONMENT_NAME}' first."
  assert_required_ecr_images_exist "$(get_parameter_override EnableFrontendRuntime)"
fi

log "Creating CloudFormation change set"
create_change_set

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run complete"
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

log "Executing CloudFormation change set"
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

log "Monitoring CloudFormation and ECS while stack update runs"
start_watchers
wait_stack_terminal
cleanup_watchers

if ! is_stack_success_status "$STACK_FINAL_STATUS"; then
  print_recent_stack_events
  print_recent_stopped_tasks "$DEPLOY_STARTED_AT"
  report_log_findings "$(backend_log_group)" "$DEPLOY_STARTED_AT"
  die "Deployment failed with stack status ${STACK_FINAL_STATUS}"
fi

run_post_deploy_checks
log "Deployment complete and healthy"
