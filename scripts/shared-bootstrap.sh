#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/shared/.env"
STACK_NAME="sendu-plugin2-shared-ecr"
TEMPLATE_FILE="${ROOT_DIR}/shared/template.yaml"
PROJECT_NAME="sendu-plugin2"
AWS_PROFILE_NAME="sendu"
AWS_REGION_NAME="us-east-2"
DRY_RUN=false

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  AWS_PROFILE_NAME="${DEPLOY_AWS_PROFILE:-${AWS_PROFILE:-${AWS_PROFILE_NAME}}}"
  AWS_REGION_NAME="${DEPLOY_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-${AWS_REGION_NAME}}}}"
fi

usage() {
  cat <<'EOF'
Usage:
  ./scripts/shared-bootstrap.sh [options]

Deploy the shared ECR stack in us-east-2.

Options:
  --profile <name>     AWS CLI profile
  --region <region>    AWS region
  --dry-run             Print the deployment command only
  -h, --help            Show this help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      AWS_PROFILE_NAME="${2:?Missing value for --profile}"
      shift 2
      ;;
    --region)
      AWS_REGION_NAME="${2:?Missing value for --region}"
      shift 2
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
      die "Unknown option: $1"
      ;;
  esac
done

require_cmd aws

COMMAND=(
  aws cloudformation deploy
  --stack-name "$STACK_NAME"
  --template-file "$TEMPLATE_FILE"
  --parameter-overrides "ProjectName=${PROJECT_NAME}"
  --profile "$AWS_PROFILE_NAME"
  --region "$AWS_REGION_NAME"
  --no-fail-on-empty-changeset
)

VALIDATE_COMMAND=(
  aws cloudformation validate-template
  --template-body "file://${TEMPLATE_FILE}"
  --profile "$AWS_PROFILE_NAME"
  --region "$AWS_REGION_NAME"
)

printf 'Shared stack: %s\n' "$STACK_NAME"
printf 'Template: %s\n' "$TEMPLATE_FILE"
printf 'Profile: %s\n' "$AWS_PROFILE_NAME"
printf 'Region: %s\n' "$AWS_REGION_NAME"

if [[ "$DRY_RUN" == "true" ]]; then
  printf '+ %s\n' "$(quote_args "${VALIDATE_COMMAND[@]}")"
  printf '+ %s\n' "$(quote_args "${COMMAND[@]}")"
  exit 0
fi

"${VALIDATE_COMMAND[@]}" >/dev/null
"${COMMAND[@]}"
