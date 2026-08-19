#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/shared/.env"
AWS_PROFILE_NAME="sendu"
SOURCE_STACK="sendu-plugin2-prod"
SOURCE_REGION="us-east-2"
DESTINATION_STACK="sendu-plugin2-shared-ecr"
DESTINATION_REGION="us-east-2"
BACKEND_IMAGE_TAG=""
FRONTEND_IMAGE_TAG=""

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
  AWS_PROFILE_NAME="${DEPLOY_AWS_PROFILE:-${AWS_PROFILE:-${AWS_PROFILE_NAME}}}"
  DESTINATION_REGION="${DEPLOY_AWS_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-${DESTINATION_REGION}}}}"
fi

usage() {
  cat <<'EOF'
Usage:
  ./scripts/ecr-migrate.sh [options]

Copy existing ECR image tags into the shared us-east-2 repositories.

Options:
  --profile <name>             AWS CLI profile
  --source-stack <name>        Stack containing the source repository outputs
  --source-region <region>     Region containing the source stack/repositories
  --backend-image-tag <tag>    Copy a backend image tag
  --frontend-image-tag <tag>   Copy a frontend image tag
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

aws_source() {
  aws --profile "$AWS_PROFILE_NAME" --region "$SOURCE_REGION" "$@"
}

aws_destination() {
  aws --profile "$AWS_PROFILE_NAME" --region "$DESTINATION_REGION" "$@"
}

stack_output() {
  local region="$1"
  local stack="$2"
  local key="$3"
  aws --profile "$AWS_PROFILE_NAME" --region "$region" cloudformation describe-stacks \
    --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text 2>/dev/null || true
}

copy_image() {
  local label="$1"
  local output_key="$2"
  local image_tag="$3"
  local source_uri
  local destination_uri
  local source_repository
  local destination_repository
  local source_digest
  local destination_digest
  local manifest
  local copied_digest

  [[ -n "$image_tag" ]] || return 0

  source_uri="$(stack_output "$SOURCE_REGION" "$SOURCE_STACK" "$output_key")"
  destination_uri="$(stack_output "$DESTINATION_REGION" "$DESTINATION_STACK" "$output_key")"
  [[ -n "$source_uri" && "$source_uri" != "None" ]] || die "Could not resolve source ${output_key}"
  [[ -n "$destination_uri" && "$destination_uri" != "None" ]] || die "Could not resolve destination ${output_key}; deploy shared stack first"

  source_repository="${source_uri#*/}"
  destination_repository="${destination_uri#*/}"
  source_digest="$(aws_source ecr describe-images \
    --repository-name "$source_repository" \
    --image-ids "imageTag=${image_tag}" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null || true)"
  [[ -n "$source_digest" && "$source_digest" != "None" ]] || die "Source ${label} image '${image_tag}' does not exist"

  destination_digest="$(aws_destination ecr describe-images \
    --repository-name "$destination_repository" \
    --image-ids "imageTag=${image_tag}" \
    --query 'imageDetails[0].imageDigest' \
    --output text 2>/dev/null || true)"
  if [[ -n "$destination_digest" && "$destination_digest" != "None" ]]; then
    [[ "$destination_digest" == "$source_digest" ]] || die "Destination ${label} tag '${image_tag}' already points to a different digest"
    printf '%s %s already migrated: %s\n' "$label" "$image_tag" "$source_digest"
    return
  fi

  manifest="$(aws_source ecr batch-get-image \
    --repository-name "$source_repository" \
    --image-ids "imageTag=${image_tag}" \
    --query 'images[0].imageManifest' \
    --output text)"
  [[ -n "$manifest" && "$manifest" != "None" ]] || die "Could not read ${label} image manifest for '${image_tag}'"

  aws_destination ecr put-image \
    --repository-name "$destination_repository" \
    --image-tag "$image_tag" \
    --image-manifest "$manifest" >/dev/null

  copied_digest="$(aws_destination ecr describe-images \
    --repository-name "$destination_repository" \
    --image-ids "imageTag=${image_tag}" \
    --query 'imageDetails[0].imageDigest' \
    --output text)"
  [[ "$copied_digest" == "$source_digest" ]] || die "Digest mismatch after copying ${label} image '${image_tag}'"
  printf '%s %s migrated: %s\n' "$label" "$image_tag" "$copied_digest"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      AWS_PROFILE_NAME="${2:?Missing value for --profile}"
      shift 2
      ;;
    --source-stack)
      SOURCE_STACK="${2:?Missing value for --source-stack}"
      shift 2
      ;;
    --source-region)
      SOURCE_REGION="${2:?Missing value for --source-region}"
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
[[ -n "$BACKEND_IMAGE_TAG" || -n "$FRONTEND_IMAGE_TAG" ]] || die "Provide at least one image tag to migrate"

copy_image "Backend" BackendEcrRepositoryUri "$BACKEND_IMAGE_TAG"
copy_image "Frontend" FrontendEcrRepositoryUri "$FRONTEND_IMAGE_TAG"
