#!/usr/bin/env bash

ecs_cluster_name() {
  printf 'sendu-plugin2-%s-ecs' "$ENVIRONMENT_NAME"
}

ecs_service_name() {
  printf 'sendu-plugin2-%s-backend' "$ENVIRONMENT_NAME"
}

backend_log_group() {
  printf '/ecs/sendu-plugin2/%s/backend' "$ENVIRONMENT_NAME"
}

describe_ecs_service() {
  aws ecs describe-services \
    --cluster "$(ecs_cluster_name)" \
    --services "$(ecs_service_name)" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    "$@"
}

print_ecs_service_status() {
  describe_ecs_service \
    --query 'services[0].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount,Deployments:deployments[].{Status:status,Rollout:rolloutState,Desired:desiredCount,Running:runningCount,Pending:pendingCount,TaskDefinition:taskDefinition}}' \
    --output table 2>/dev/null || warn "Could not describe ECS service $(ecs_service_name)"
}

wait_ecs_stable() {
  aws ecs wait services-stable \
    --cluster "$(ecs_cluster_name)" \
    --services "$(ecs_service_name)" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION"
}

print_recent_stopped_tasks() {
  local since_epoch="$1"
  local seen_file="${2:-}"
  local task_arns=""
  local task_arn=""
  local task_id=""
  local stream=""
  local log_group=""
  local stopped_at=""
  local stopped_epoch=""

  task_arns="$(aws ecs list-tasks \
    --cluster "$(ecs_cluster_name)" \
    --desired-status STOPPED \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'taskArns[0:10]' \
    --output text 2>/dev/null || true)"

  [[ -n "$task_arns" && "$task_arns" != "None" ]] || return

  log_group="$(backend_log_group)"

  for task_arn in $task_arns; do
    if [[ -n "$seen_file" ]] && grep -Fxq "$task_arn" "$seen_file" 2>/dev/null; then
      continue
    fi

    stopped_at="$(aws ecs describe-tasks \
      --cluster "$(ecs_cluster_name)" \
      --tasks "$task_arn" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query 'tasks[0].stoppedAt' \
      --output text 2>/dev/null || true)"

    if [[ -n "$stopped_at" && "$stopped_at" != "None" ]]; then
      stopped_epoch="$(date -d "$stopped_at" +%s 2>/dev/null || true)"
      if [[ -n "$stopped_epoch" ]] && ((stopped_epoch < since_epoch)); then
        [[ -n "$seen_file" ]] && printf '%s\n' "$task_arn" >>"$seen_file"
        continue
      fi

      if [[ -z "$stopped_epoch" ]]; then
        warn "Could not parse stoppedAt '${stopped_at}' for ${task_arn}; printing diagnostics anyway"
      fi
    fi

    task_id="${task_arn##*/}"

    aws ecs describe-tasks \
      --cluster "$(ecs_cluster_name)" \
      --tasks "$task_arn" \
      --profile "$AWS_PROFILE" \
      --region "$AWS_REGION" \
      --query 'tasks[0].{StoppedAt:stoppedAt,StoppedReason:stoppedReason,Containers:containers[].{Name:name,ExitCode:exitCode,Reason:reason,LastStatus:lastStatus}}' \
      --output table 2>/dev/null || true

    stream="backend/backend/${task_id}"
    printf 'Recent logs for stopped task %s:\n' "$task_id"
    print_log_stream_tail "$log_group" "$stream"

    [[ -n "$seen_file" ]] && printf '%s\n' "$task_arn" >>"$seen_file"
  done
}

watch_ecs_rollout() {
  local since_epoch="$1"
  local seen_file="${2:-}"

  while true; do
    print_ecs_service_status
    print_recent_stopped_tasks "$since_epoch" "$seen_file"
    sleep 15
  done
}

target_group_arn() {
  aws elbv2 describe-target-groups \
    --names "sendu-plugin2-${ENVIRONMENT_NAME}-tg" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || true
}

check_alb_target_health() {
  local tg_arn=""
  tg_arn="$(target_group_arn)"

  [[ -n "$tg_arn" && "$tg_arn" != "None" ]] || die "Could not resolve backend target group ARN"

  aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
    --output table

  local healthy unhealthy draining
  healthy="$(aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text)"
  unhealthy="$(aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State!='healthy' && TargetHealth.State!='draining'])" \
    --output text)"
  draining="$(aws elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='draining'])" \
    --output text)"

  [[ "$healthy" != "0" ]] || die "No healthy ALB targets are serving traffic"
  [[ "$unhealthy" == "0" ]] || die "One or more ALB targets are unhealthy"
  if [[ "$draining" != "0" ]]; then
    warn "${draining} ALB target(s) are still draining; healthy target(s) are serving traffic"
  fi
}
