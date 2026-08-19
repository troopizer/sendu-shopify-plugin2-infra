#!/usr/bin/env bash

repository_name_from_uri() {
  local repository_uri="$1"

  if [[ "$repository_uri" != */* ]]; then
    return 1
  fi

  printf '%s' "${repository_uri#*/}"
}

assert_ecr_image_exists() {
  local label="$1"
  local repository_output_key="$2"
  local image_tag="$3"
  local repository_uri=""
  local repository_name=""

  [[ -n "$image_tag" ]] || die "Missing ${label} image tag"

  repository_uri="$(stack_output "$repository_output_key")"
  [[ -n "$repository_uri" && "$repository_uri" != "None" ]] || die "Could not resolve ${repository_output_key}. Run bootstrap first."

  repository_name="$(repository_name_from_uri "$repository_uri")" || die "Could not parse ECR repository name from ${repository_uri}"

  if ! aws ecr describe-images \
    --repository-name "$repository_name" \
    --image-ids "imageTag=${image_tag}" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" >/dev/null 2>&1; then
    die "${label} image '${repository_uri}:${image_tag}' does not exist in ECR"
  fi

  printf '  %s image: %s:%s\n' "$label" "$repository_uri" "$image_tag"
}

assert_required_ecr_images_exist() {
  local enable_frontend_runtime="${1:-true}"

  log "Checking ECR images"
  assert_ecr_image_exists "backend" "BackendEcrRepositoryUri" "$BACKEND_IMAGE_TAG"

  if [[ "$enable_frontend_runtime" != "false" ]]; then
    assert_ecr_image_exists "frontend" "FrontendEcrRepositoryUri" "$FRONTEND_IMAGE_TAG"
  fi
}
