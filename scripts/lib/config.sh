#!/usr/bin/env bash

resolve_repo_path() {
  local path="$1"

  if [[ "$path" == /* ]]; then
    printf '%s' "$path"
  else
    printf '%s/%s' "$ROOT_DIR" "$path"
  fi
}

resolve_profile_region() {
  aws configure get region --profile "$1" 2>/dev/null || true
}

load_env_file() {
  ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

  if [[ -f "$ENV_FILE" ]]; then
    log "Loading defaults from ${ENV_FILE}"
    set -a
    # shellcheck source=/dev/null
    . "$ENV_FILE"
    set +a
  fi
}

init_config_defaults() {
  ARG_AWS_PROFILE=""
  ARG_AWS_REGION=""
  ARG_ENVIRONMENT=""
  ARG_ENVIRONMENT_DIR=""
  ARG_STACK_NAME=""
  ARG_TEMPLATE_FILE=""
  ARG_PARAMETERS_FILE=""
  ARG_BACKEND_IMAGE_TAG=""
  ARG_FRONTEND_IMAGE_TAG=""
  ARG_VERSION=""
}

parse_common_arg() {
  PARSE_COMMON_CONSUMED=0

  case "${1:-}" in
    --environment)
      ARG_ENVIRONMENT="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --environment-dir)
      ARG_ENVIRONMENT_DIR="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --profile)
      ARG_AWS_PROFILE="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --region)
      ARG_AWS_REGION="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --stack-name)
      ARG_STACK_NAME="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --template-file)
      ARG_TEMPLATE_FILE="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --parameters-file)
      ARG_PARAMETERS_FILE="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --version|--image-tag)
      ARG_VERSION="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --backend-image-tag|--backend-version)
      ARG_BACKEND_IMAGE_TAG="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    --frontend-image-tag|--frontend-version)
      ARG_FRONTEND_IMAGE_TAG="${2:-}"
      PARSE_COMMON_CONSUMED=2
      ;;
    *)
      return 1
      ;;
  esac

  [[ -n "${2:-}" ]] || die "Missing value for $1"
  return 0
}

resolve_deploy_config() {
  AWS_PROFILE="${ARG_AWS_PROFILE:-${DEPLOY_AWS_PROFILE:-${AWS_PROFILE:-default}}}"
  AWS_REGION="${ARG_AWS_REGION:-${DEPLOY_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}}"
  ENVIRONMENT_NAME="${ARG_ENVIRONMENT:-${DEPLOY_ENVIRONMENT:-staging}}"

  case "$ENVIRONMENT_NAME" in
    staging|prod) ;;
    *) die "Environment must be staging or prod, got: ${ENVIRONMENT_NAME}" ;;
  esac

  if [[ -n "$ARG_ENVIRONMENT_DIR" ]]; then
    ENVIRONMENT_DIR="$ARG_ENVIRONMENT_DIR"
  elif [[ -n "$ARG_ENVIRONMENT" ]]; then
    ENVIRONMENT_DIR="$ENVIRONMENT_NAME"
  else
    ENVIRONMENT_DIR="${DEPLOY_ENVIRONMENT_DIR:-${ENVIRONMENT_NAME}}"
  fi

  ENVIRONMENT_DIR="$(resolve_repo_path "$ENVIRONMENT_DIR")"

  if [[ -n "$ARG_TEMPLATE_FILE" ]]; then
    TEMPLATE_FILE="$ARG_TEMPLATE_FILE"
  elif [[ -n "$ARG_ENVIRONMENT" ]]; then
    TEMPLATE_FILE="${ENVIRONMENT_DIR}/template.yaml"
  else
    TEMPLATE_FILE="${DEPLOY_TEMPLATE_FILE:-${ENVIRONMENT_DIR}/template.yaml}"
  fi

  if [[ -n "$ARG_STACK_NAME" ]]; then
    STACK_NAME="$ARG_STACK_NAME"
  elif [[ -n "$ARG_ENVIRONMENT" ]]; then
    STACK_NAME="sendu-plugin2-${ENVIRONMENT_NAME}"
  else
    STACK_NAME="${DEPLOY_INFRA_STACK_NAME:-${DEPLOY_STACK_NAME:-sendu-plugin2-${ENVIRONMENT_NAME}}}"
  fi

  if [[ -n "$ARG_PARAMETERS_FILE" ]]; then
    PARAMETERS_FILE="$ARG_PARAMETERS_FILE"
  elif [[ -n "$ARG_ENVIRONMENT" ]]; then
    PARAMETERS_FILE="${ENVIRONMENT_DIR}/parameters.json"
  else
    PARAMETERS_FILE="${DEPLOY_PARAMETERS_FILE:-${ENVIRONMENT_DIR}/parameters.json}"
  fi

  TEMPLATE_FILE="$(resolve_repo_path "$TEMPLATE_FILE")"
  PARAMETERS_FILE="$(resolve_repo_path "$PARAMETERS_FILE")"

  if [[ -z "$AWS_REGION" ]]; then
    AWS_REGION="$(resolve_profile_region "$AWS_PROFILE")"
  fi

  [[ -n "$AWS_REGION" ]] || die "Missing AWS region. Provide --region, set DEPLOY_AWS_REGION/AWS_REGION, or configure region for profile ${AWS_PROFILE}"
  [[ -d "$ENVIRONMENT_DIR" ]] || die "Environment directory not found: ${ENVIRONMENT_DIR}"
  [[ -f "$TEMPLATE_FILE" ]] || die "Template file not found: ${TEMPLATE_FILE}"
  [[ -f "$PARAMETERS_FILE" ]] || die "Parameters file not found: ${PARAMETERS_FILE}"

  BACKEND_IMAGE_TAG="${ARG_BACKEND_IMAGE_TAG:-${ARG_VERSION}}"
  FRONTEND_IMAGE_TAG="${ARG_FRONTEND_IMAGE_TAG:-${ARG_VERSION}}"
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

get_parameter_override() {
  local key="$1"
  local existing_override=""

  for existing_override in "${PARAMETER_OVERRIDES[@]}"; do
    if [[ "$existing_override" == "${key}="* ]]; then
      printf '%s' "${existing_override#*=}"
      return
    fi
  done
}

require_image_tags() {
  [[ -n "$BACKEND_IMAGE_TAG" ]] || die "Missing --version or --backend-image-tag"
  [[ -n "$FRONTEND_IMAGE_TAG" ]] || die "Missing --version or --frontend-image-tag"
}

print_resolved_config() {
  printf '  profile: %s\n' "$AWS_PROFILE"
  printf '  region: %s\n' "$AWS_REGION"
  printf '  environment: %s\n' "$ENVIRONMENT_NAME"
  printf '  environment dir: %s\n' "$ENVIRONMENT_DIR"
  printf '  stack: %s\n' "$STACK_NAME"
  printf '  template: %s\n' "$TEMPLATE_FILE"
  printf '  parameters: %s\n' "$PARAMETERS_FILE"
  printf '  backend image tag: %s\n' "${BACKEND_IMAGE_TAG:-[from parameters]}"
  printf '  frontend image tag: %s\n' "${FRONTEND_IMAGE_TAG:-[from parameters]}"
}
