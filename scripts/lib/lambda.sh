#!/usr/bin/env bash

lambda_function_name() {
  printf 'sendu-plugin2-%s-front' "$ENVIRONMENT_NAME"
}

lambda_log_group() {
  printf '/aws/lambda/sendu-plugin2-%s-front' "$ENVIRONMENT_NAME"
}

check_lambda_status() {
  local function_name
  function_name="$(lambda_function_name)"

  aws lambda get-function-configuration \
    --function-name "$function_name" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query '{State:State,LastUpdateStatus:LastUpdateStatus,LastUpdateStatusReason:LastUpdateStatusReason,PackageType:PackageType}' \
    --output table

  local state update_status
  state="$(aws lambda get-function-configuration \
    --function-name "$function_name" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query State \
    --output text)"
  update_status="$(aws lambda get-function-configuration \
    --function-name "$function_name" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query LastUpdateStatus \
    --output text)"

  [[ "$state" == "Active" ]] || die "Lambda ${function_name} is not Active: ${state}"
  [[ "$update_status" == "Successful" ]] || die "Lambda ${function_name} update is not Successful: ${update_status}"
}

print_lambda_errors() {
  report_log_findings "$(lambda_log_group)" "$1"
}
