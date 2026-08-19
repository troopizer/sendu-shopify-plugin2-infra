#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/shared/.env"
STACK_NAME="sendu-plugin2-shared-ecr"
AWS_PROFILE_NAME="sendu"
AWS_REGION_NAME="us-east-2"
BACKEND_IMAGE_TAG=""
FRONTEND_IMAGE_TAG=""

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
  ./scripts/ecr-verify.sh [options]

The shared stack owns the ECR repositories used by staging and prod.

Options:
  --profile <name>             AWS CLI profile
  --region <region>            AWS region
  --backend-image-tag <tag>    Verify a backend image tag exists
  --frontend-image-tag <tag>   Verify a frontend image tag exists
  -h, --help                   Show this help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

aws_cli() {
  aws --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME" "$@"
}

stack_output() {
  local key="$1"
  aws_cli cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text 2>/dev/null || true
}

verify_repository() {
  local label="$1"
  local uri="$2"
  local expected_tag="$3"
  local repository_name="${uri#*/}"
  local scan_on_push
  local tag_mutability

  [[ -n "$uri" && "$uri" != "None" && "$uri" == */* ]] || die "Could not resolve ${label} repository URI from ${STACK_NAME}"

  scan_on_push="$(aws_cli ecr describe-repositories \
    --repository-names "$repository_name" \
    --query 'repositories[0].imageScanningConfiguration.scanOnPush' \
    --output text)"
  tag_mutability="$(aws_cli ecr describe-repositories \
    --repository-names "$repository_name" \
    --query 'repositories[0].imageTagMutability' \
    --output text)"

  [[ "$scan_on_push" == "True" ]] || die "${label} repository does not have scan-on-push enabled"
  printf '%s repository: %s\n' "$label" "$uri"
  printf '  scan on push: %s\n' "$scan_on_push"
  printf '  tag mutability: %s\n' "$tag_mutability"

  if [[ -n "$expected_tag" ]]; then
    local digest
    digest="$(aws_cli ecr describe-images \
      --repository-name "$repository_name" \
      --image-ids "imageTag=${expected_tag}" \
      --query 'imageDetails[0].imageDigest' \
      --output text 2>/dev/null || true)"
    [[ -n "$digest" && "$digest" != "None" ]] || die "${label} image tag '${expected_tag}' does not exist"
    printf '  %s digest: %s\n' "$expected_tag" "$digest"
  fi
}

verify_lambda_policy() {
  local repository_name="$1"
  local policy
  policy="$(aws_cli ecr get-repository-policy \
    --repository-name "$repository_name" \
    --query policyText \
    --output text 2>/dev/null || true)"
  [[ -n "$policy" && "$policy" != "None" ]] || die "No repository policy found for ${repository_name}"

  printf '%s' "$policy" | jq -e --arg staging "arn:aws:lambda:${AWS_REGION_NAME}:$(aws_cli sts get-caller-identity --query Account --output text):function:sendu-plugin2-staging-front" \
    --arg prod "arn:aws:lambda:${AWS_REGION_NAME}:$(aws_cli sts get-caller-identity --query Account --output text):function:sendu-plugin2-prod-front" '
      .Statement
      | any(.[];
          .Condition.StringLike["aws:sourceArn"] as $sources
          | (if ($sources | type) == "array" then $sources else [$sources] end)
          | index($staging) != null and index($prod) != null
        )
    ' >/dev/null || die "${repository_name} policy does not allow both staging and prod Lambda pulls"
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
    --backend-image-tag)
      BACKEND_IMAGE_TAG="${2:?Missing value for --backend-image-tag}"
      shift 2
      ;;
    --frontend-image-tag)
      FRONTEND_IMAGE_TAG="${2:?Missing value for --frontend-image-tag}"
      shift 2
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
require_cmd jq

backend_uri="$(stack_output BackendEcrRepositoryUri)"
frontend_uri="$(stack_output FrontendEcrRepositoryUri)"
verify_repository "Backend" "$backend_uri" "$BACKEND_IMAGE_TAG"
verify_repository "Frontend" "$frontend_uri" "$FRONTEND_IMAGE_TAG"
verify_lambda_policy "${frontend_uri#*/}"

printf 'Shared ECR verification passed for %s in %s.\n' "$STACK_NAME" "$AWS_REGION_NAME"
