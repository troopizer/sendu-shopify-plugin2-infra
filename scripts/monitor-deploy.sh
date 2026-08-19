#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SINCE_EPOCH="$(date +%s)"
SKIP_HTTP=false

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
  ./scripts/monitor-deploy.sh [options]

Options:
  --environment <name>                Environment folder/name: staging or prod
  --version <tag>                     Image tag for backend and frontend checks
  --backend-image-tag <tag>           Backend image tag
  --frontend-image-tag <tag>          Frontend image tag
  --profile <aws-profile>             AWS profile
  --region <aws-region>               AWS region
  --skip-http                         Skip frontend/backend HTTP health checks
  -h, --help                          Show this help
EOF
}

init_config_defaults
load_env_file

while [[ $# -gt 0 ]]; do
  if parse_common_arg "$@"; then
    shift "$PARSE_COMMON_CONSUMED"
    continue
  fi

  case "$1" in
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

require_cmd aws
require_cmd jq
resolve_deploy_config
load_parameter_overrides

BACKEND_IMAGE_TAG="${BACKEND_IMAGE_TAG:-$(get_parameter_override BackendImageTag)}"
FRONTEND_IMAGE_TAG="${FRONTEND_IMAGE_TAG:-$(get_parameter_override FrontendImageTag)}"
require_image_tags

stack_exists || die "CloudFormation stack '${STACK_NAME}' does not exist"

log "Resolved monitor values"
print_resolved_config

log "Checking CloudFormation stack health"
check_stack_healthy

assert_required_ecr_images_exist "$(get_parameter_override EnableFrontendRuntime)"

log "Checking ECS service"
print_ecs_service_status
wait_ecs_stable

log "Checking ALB target health"
check_alb_target_health

if [[ "$(get_parameter_override EnableFrontendRuntime)" != "false" ]]; then
  log "Checking Lambda status"
  check_lambda_status
fi

if [[ "$SKIP_HTTP" != "true" ]]; then
  log "Running HTTP health checks"
  check_backend_health
  if [[ "$(get_parameter_override EnableFrontendRuntime)" != "false" ]]; then
    check_frontend_health
  fi
fi

log "Checking recent backend errors"
report_log_findings "$(backend_log_group)" "$SINCE_EPOCH"

if [[ "$(get_parameter_override EnableFrontendRuntime)" != "false" ]]; then
  log "Checking recent Lambda errors"
  print_lambda_errors "$SINCE_EPOCH"
fi

log "Monitor checks complete"
