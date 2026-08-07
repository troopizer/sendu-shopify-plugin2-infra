#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_DIR="$(cd "${ROOT_DIR}/.." && pwd)"
BACKEND_DIR="${BACKEND_DIR:-${WORKSPACE_DIR}/sendu-shopify-plugin2-backend}"
FRONTEND_DIR="${FRONTEND_DIR:-${WORKSPACE_DIR}/sendu-shopify-plugin2-frontend}"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

DRY_RUN=false
PUSH_LATEST=true

ARG_AWS_PROFILE=""
ARG_AWS_REGION=""
ARG_STACK_NAME=""
ARG_PARAMETERS_FILE=""
ARG_IMAGE_TAG=""
ARG_API_BASE_URL=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-all.sh [options]

Most-used release flow:
  1) Build and push backend image
  2) Build and push frontend Lambda image
  3) Deploy CloudFormation with both image tags

If --image-tag is omitted, the tag defaults to the current git commit SHA.

Options:
  --profile <aws-profile>             AWS profile (default: DEPLOY_AWS_PROFILE, AWS_PROFILE, or default)
  --region <aws-region>               AWS region (default: DEPLOY_AWS_REGION, AWS_REGION, AWS_DEFAULT_REGION, or AWS profile config)
  --stack-name <stack-name>           CloudFormation stack name (default: DEPLOY_INFRA_STACK_NAME, DEPLOY_STACK_NAME, or sendu-plugin2-staging)
  --parameters-file <path>            CloudFormation parameter JSON (default: parameters.staging.json)
  --image-tag <tag>                   Image tag for both backend and frontend (default: current git commit SHA)
  --api-base-url <url>                Frontend VITE_API_BASE_URL override
  --no-latest                         Skip tagging/pushing :latest
  --dry-run                           Print commands without executing them
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

stack_exists() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null 2>&1
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

resolve_api_base_url() {
  local value=""

  value="$(stack_output FrontendApiBaseUrl)"
  if [[ -n "$value" && "$value" != "None" ]]; then
    printf '%s' "$value"
    return
  fi

  value="$(stack_output FrontendApiUrl)"
  if [[ -n "$value" && "$value" != "None" ]]; then
    printf '%s/api' "${value%/}"
    return
  fi

  printf '/api'
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

git_commit_tag() {
  local candidate=""
  for candidate in "$ROOT_DIR" "$WORKSPACE_DIR" "$BACKEND_DIR" "$FRONTEND_DIR"; do
    if git -C "$candidate" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$candidate" rev-parse --short=12 HEAD
      return 0
    fi
  done

  return 1
}

quote_args() {
  local quoted=()
  local arg
  for arg in "$@"; do
    quoted+=("$(printf '%q' "$arg")")
  done
  printf '%s' "${quoted[*]}"
}

run_command() {
  local -a command=("$@")

  if [[ "$DRY_RUN" == "true" ]]; then
    printf '+ %s\n' "$(quote_args "${command[@]}")"
    return
  fi

  "${command[@]}"
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
      --image-tag)
        ARG_IMAGE_TAG="${2:-}"
        shift 2
        ;;
      --api-base-url)
        ARG_API_BASE_URL="${2:-}"
        shift 2
        ;;
      --no-latest)
        PUSH_LATEST=false
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

load_env_file
parse_args "$@"

AWS_PROFILE="${ARG_AWS_PROFILE:-${DEPLOY_AWS_PROFILE:-${AWS_PROFILE:-default}}}"
AWS_REGION="${ARG_AWS_REGION:-${DEPLOY_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}}"
STACK_NAME="${ARG_STACK_NAME:-${DEPLOY_INFRA_STACK_NAME:-${DEPLOY_STACK_NAME:-sendu-plugin2-staging}}}"
PARAMETERS_FILE="${ARG_PARAMETERS_FILE:-${DEPLOY_PARAMETERS_FILE:-${ROOT_DIR}/parameters.staging.json}}"
IMAGE_TAG="$ARG_IMAGE_TAG"

require_cmd aws
require_cmd git

if [[ -z "$AWS_REGION" ]]; then
  AWS_REGION="$(resolve_profile_region "$AWS_PROFILE")"
fi

if [[ -z "$IMAGE_TAG" ]]; then
  IMAGE_TAG="$(git_commit_tag || true)"
fi

[[ -n "$AWS_REGION" ]] || die "Missing AWS region. Provide --region, set DEPLOY_AWS_REGION/AWS_REGION, or configure region for profile ${AWS_PROFILE}"
[[ -n "$IMAGE_TAG" ]] || die "Missing --image-tag and no git repository was found to resolve the current commit SHA"
[[ -f "$PARAMETERS_FILE" ]] || die "Parameters file not found: ${PARAMETERS_FILE}"
[[ -x "${BACKEND_DIR}/scripts/release-and-push-ecr.sh" ]] || die "Missing backend release script: ${BACKEND_DIR}/scripts/release-and-push-ecr.sh"
[[ -x "${FRONTEND_DIR}/scripts/release-and-push-ecr.sh" ]] || die "Missing frontend release script: ${FRONTEND_DIR}/scripts/release-and-push-ecr.sh"
[[ -x "${ROOT_DIR}/scripts/deploy-stack.sh" ]] || die "Missing infra deploy script: ${ROOT_DIR}/scripts/deploy-stack.sh"

if [[ "$DRY_RUN" != "true" ]] && ! stack_exists; then
  die "CloudFormation stack '${STACK_NAME}' does not exist for profile '${AWS_PROFILE}' in region '${AWS_REGION}'. Run './scripts/deploy-stack.sh --bootstrap' first, or pass the existing stack with --stack-name."
fi

API_BASE_URL="${ARG_API_BASE_URL:-${VITE_API_BASE_URL:-}}"
if [[ -z "$API_BASE_URL" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    API_BASE_URL="/api"
  else
    API_BASE_URL="$(resolve_api_base_url)"
  fi
fi

COMMON_IMAGE_ARGS=(
  --profile "$AWS_PROFILE"
  --region "$AWS_REGION"
  --infra-stack-name "$STACK_NAME"
  --image-tag "$IMAGE_TAG"
)

if [[ "$PUSH_LATEST" == "false" ]]; then
  COMMON_IMAGE_ARGS+=(--no-latest)
fi

FRONTEND_IMAGE_ARGS=("${COMMON_IMAGE_ARGS[@]}")
FRONTEND_IMAGE_ARGS+=(--api-base-url "$API_BASE_URL")

DEPLOY_ARGS=(
  --profile "$AWS_PROFILE"
  --region "$AWS_REGION"
  --stack-name "$STACK_NAME"
  --parameters-file "$PARAMETERS_FILE"
  --backend-image-tag "$IMAGE_TAG"
  --frontend-image-tag "$IMAGE_TAG"
  --enable-frontend-runtime true
  --backend-desired-count 1
)

log "Resolved release values"
printf '  profile: %s\n' "$AWS_PROFILE"
printf '  region: %s\n' "$AWS_REGION"
printf '  stack: %s\n' "$STACK_NAME"
printf '  parameters: %s\n' "$PARAMETERS_FILE"
printf '  image tag: %s\n' "$IMAGE_TAG"
printf '  push latest: %s\n' "$PUSH_LATEST"
printf '  backend dir: %s\n' "$BACKEND_DIR"
printf '  frontend dir: %s\n' "$FRONTEND_DIR"
printf '  api base url: %s\n' "$API_BASE_URL"

log "Step 1/3: backend image"
run_command "${BACKEND_DIR}/scripts/release-and-push-ecr.sh" "${COMMON_IMAGE_ARGS[@]}"

log "Step 2/3: frontend image"
run_command "${FRONTEND_DIR}/scripts/release-and-push-ecr.sh" "${FRONTEND_IMAGE_ARGS[@]}"

log "Step 3/3: stack deploy"
run_command "${ROOT_DIR}/scripts/deploy-stack.sh" "${DEPLOY_ARGS[@]}"

log "Release complete"
printf '  deployed image tag: %s\n' "$IMAGE_TAG"
