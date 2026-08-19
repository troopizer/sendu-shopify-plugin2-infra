#!/usr/bin/env bash

repository_name_from_uri() {
  local repository_uri="$1"

  if [[ "$repository_uri" != */* ]]; then
    return 1
  fi

  printf '%s' "${repository_uri#*/}"
}

shared_ecr_stack_output() {
  local key="$1"

  aws cloudformation describe-stacks \
    --stack-name sendu-plugin2-shared-ecr \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" 2>/dev/null || true
}

latest_published_ecr_tag() {
  local label="$1"
  local repository_output_key="$2"
  local repository_uri=""
  local repository_name=""
  local image_tag=""

  repository_uri="$(shared_ecr_stack_output "$repository_output_key")"
  [[ -n "$repository_uri" && "$repository_uri" != "None" ]] || die "Could not resolve ${repository_output_key} from sendu-plugin2-shared-ecr. Run shared bootstrap first."

  repository_name="$(repository_name_from_uri "$repository_uri")" || die "Could not parse ECR repository name from ${repository_uri}"
  image_tag="$(aws ecr describe-images \
    --repository-name "$repository_name" \
    --filter tagStatus=TAGGED \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --output json | jq -r '
      [
        .imageDetails[]?
        | select(.imageTags != null)
        | . as $image
        | $image.imageTags[]
        | {tag: ., pushedAt: $image.imagePushedAt}
      ]
      | sort_by(.pushedAt)
      | if ([.[] | select(.tag != "latest")] | length) > 0
        then ([.[] | select(.tag != "latest")] | .[-1].tag)
        else .[-1].tag
        end
    ')"

  [[ -n "$image_tag" && "$image_tag" != "null" ]] || die "Could not resolve the latest published ${label} image in ${repository_uri}"
  printf '%s' "$image_tag"
}

resolve_missing_image_tags() {
  if [[ -z "$BACKEND_IMAGE_TAG" ]]; then
    BACKEND_IMAGE_TAG="$(latest_published_ecr_tag "backend" "BackendEcrRepositoryUri")"
  fi

  if [[ -z "$FRONTEND_IMAGE_TAG" ]]; then
    FRONTEND_IMAGE_TAG="$(latest_published_ecr_tag "frontend" "FrontendEcrRepositoryUri")"
  fi
}

assert_ecr_image_exists() {
  local label="$1"
  local repository_output_key="$2"
  local image_tag="$3"
  local repository_uri=""
  local repository_name=""

  [[ -n "$image_tag" ]] || die "Missing ${label} image tag"

  repository_uri="$(shared_ecr_stack_output "$repository_output_key")"
  [[ -n "$repository_uri" && "$repository_uri" != "None" ]] || die "Could not resolve ${repository_output_key} from sendu-plugin2-shared-ecr. Run shared bootstrap first."

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

print_ecr_summary() {
  local backend_uri
  local frontend_uri

  backend_uri="$(shared_ecr_stack_output BackendEcrRepositoryUri)"
  frontend_uri="$(shared_ecr_stack_output FrontendEcrRepositoryUri)"

  print_kv_table \
    "Backend repository" "$backend_uri" \
    "Backend tag" "$BACKEND_IMAGE_TAG" \
    "Frontend repository" "$frontend_uri" \
    "Frontend tag" "$FRONTEND_IMAGE_TAG"
}
