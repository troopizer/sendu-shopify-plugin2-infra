#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

DRY_RUN=false

ARG_AWS_PROFILE=""
ARG_AWS_REGION=""
ARG_STACK_NAME=""
ARG_PARAMETERS_FILE=""
ARG_BACKEND_IMAGE_TAG=""
ARG_FRONTEND_IMAGE_TAG=""
ARG_ENABLE_FRONTEND_RUNTIME=""
ARG_BACKEND_DESIRED_COUNT=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy-stack.sh [options]

Options:
  --profile <aws-profile>             AWS profile (default: DEPLOY_AWS_PROFILE, AWS_PROFILE, or default)
  --region <aws-region>               AWS region (default: DEPLOY_AWS_REGION, AWS_REGION, AWS_DEFAULT_REGION, or AWS profile config)
  --stack-name <stack-name>           CloudFormation stack name (default: DEPLOY_INFRA_STACK_NAME, DEPLOY_STACK_NAME, or sendu-plugin2-staging)
  --parameters-file <path>            CloudFormation parameter JSON (default: parameters.staging.json)
  --backend-image-tag <tag>           Override BackendImageTag
  --frontend-image-tag <tag>          Override FrontendImageTag
  --enable-frontend-runtime <bool>    Override EnableFrontendRuntime (true or false)
  --backend-desired-count <count>     Override BackendDesiredCount
  --bootstrap                         First deploy: BackendDesiredCount=0 and EnableFrontendRuntime=false
  --dry-run                           Print resolved values and command only
  -h, --help                          Show this help
EOF
}

log() {
  printf '==> %s\n' "$1"
}

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

resolve_profile_region() {
  aws configure get region --profile "$1" 2>/dev/null || true
}

load_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    log "Loading defaults from ${ENV_FILE}"
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        ARG_AWS_PROFILE="${2:-}"
        shift 2
        ;;
      --region)
        ARG_AWS_REGION="${2:-}"
        shift 2
        ;;
      --stack-name)
        ARG_STACK_NAME="${2:-}"
        shift 2
        ;;
      --parameters-file)
        ARG_PARAMETERS_FILE="${2:-}"
        shift 2
        ;;
      --backend-image-tag)
        ARG_BACKEND_IMAGE_TAG="${2:-}"
        shift 2
        ;;
      --frontend-image-tag)
        ARG_FRONTEND_IMAGE_TAG="${2:-}"
        shift 2
        ;;
      --enable-frontend-runtime)
        ARG_ENABLE_FRONTEND_RUNTIME="${2:-}"
        shift 2
        ;;
      --backend-desired-count)
        ARG_BACKEND_DESIRED_COUNT="${2:-}"
        shift 2
        ;;
      --bootstrap)
        ARG_BACKEND_DESIRED_COUNT="0"
        ARG_ENABLE_FRONTEND_RUNTIME="false"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
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
}

load_parameter_overrides() {
  PARAMETER_OVERRIDES=()

  while IFS= read -r parameter_override; do
    if [[ -n "$parameter_override" ]]; then
      PARAMETER_OVERRIDES+=("$parameter_override")
    fi
  done < <(jq -r '.[] | select(.ParameterKey and has("ParameterValue")) | "\(.ParameterKey)=\(.ParameterValue)"' "$PARAMETERS_FILE")
}

set_parameter_override() {
  local key="$1"
  local value="$2"
  local existing_override=""
  local updated_overrides=()

  if [[ -z "$value" ]]; then
    return
  fi

  for existing_override in "${PARAMETER_OVERRIDES[@]}"; do
    if [[ "$existing_override" != "${key}="* ]]; then
      updated_overrides+=("$existing_override")
    fi
  done

  PARAMETER_OVERRIDES=("${updated_overrides[@]}" "${key}=${value}")
}

quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${quoted[*]}"
}

load_env_file
parse_args "$@"

AWS_PROFILE="${ARG_AWS_PROFILE:-${DEPLOY_AWS_PROFILE:-${AWS_PROFILE:-default}}}"
AWS_REGION="${ARG_AWS_REGION:-${DEPLOY_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}}"
STACK_NAME="${ARG_STACK_NAME:-${DEPLOY_INFRA_STACK_NAME:-${DEPLOY_STACK_NAME:-sendu-plugin2-staging}}}"
PARAMETERS_FILE="${ARG_PARAMETERS_FILE:-${DEPLOY_PARAMETERS_FILE:-${ROOT_DIR}/parameters.staging.json}}"

require_cmd aws
require_cmd jq

if [[ -z "$AWS_REGION" ]]; then
  AWS_REGION="$(resolve_profile_region "$AWS_PROFILE")"
fi

[[ -n "$AWS_REGION" ]] || die "Missing AWS region. Provide --region, set DEPLOY_AWS_REGION/AWS_REGION, or configure region for profile ${AWS_PROFILE}"
[[ -f "$PARAMETERS_FILE" ]] || die "Parameters file not found: ${PARAMETERS_FILE}"

load_parameter_overrides
set_parameter_override "BackendImageTag" "$ARG_BACKEND_IMAGE_TAG"
set_parameter_override "FrontendImageTag" "$ARG_FRONTEND_IMAGE_TAG"
set_parameter_override "EnableFrontendRuntime" "$ARG_ENABLE_FRONTEND_RUNTIME"
set_parameter_override "BackendDesiredCount" "$ARG_BACKEND_DESIRED_COUNT"

COMMAND=(
  aws cloudformation deploy
  --stack-name "$STACK_NAME"
  --template-file "${ROOT_DIR}/template.staging.yaml"
  --parameter-overrides "${PARAMETER_OVERRIDES[@]}"
  --capabilities CAPABILITY_NAMED_IAM
  --profile "$AWS_PROFILE"
  --region "$AWS_REGION"
)

log "Resolved deploy values"
printf '  profile: %s\n' "$AWS_PROFILE"
printf '  region: %s\n' "$AWS_REGION"
printf '  stack: %s\n' "$STACK_NAME"
printf '  parameters: %s\n' "$PARAMETERS_FILE"
printf '  backend image tag: %s\n' "${ARG_BACKEND_IMAGE_TAG:-[from parameters]}"
printf '  frontend image tag: %s\n' "${ARG_FRONTEND_IMAGE_TAG:-[from parameters]}"
printf '  frontend runtime: %s\n' "${ARG_ENABLE_FRONTEND_RUNTIME:-[from parameters]}"
printf '  backend desired count: %s\n' "${ARG_BACKEND_DESIRED_COUNT:-[from parameters]}"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run mode enabled"
  printf '+ %s\n' "$(quote_args "${COMMAND[@]}")"
  exit 0
fi

log "Deploying CloudFormation stack ${STACK_NAME}"
"${COMMAND[@]}"

log "Stack deploy complete"
