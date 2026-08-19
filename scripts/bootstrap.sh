#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLAN_ONLY=false
DRY_RUN=false
CF_CHANGE_SET_TYPE=CREATE

# shellcheck source=scripts/lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
. "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/cloudformation.sh
. "${SCRIPT_DIR}/lib/cloudformation.sh"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/bootstrap.sh [options]

Options:
  --environment <name>                Environment folder/name: staging or prod
  --environment-dir <path>            Environment folder
  --profile <aws-profile>             AWS profile
  --region <aws-region>               AWS region
  --stack-name <stack-name>           CloudFormation stack name
  --template-file <path>              CloudFormation template YAML
  --parameters-file <path>            Parameter JSON
  --dry-run                           Print commands without executing them
  -h, --help                          Show this help
EOF
}

init_config_defaults
load_env_file "$@"

while [[ $# -gt 0 ]]; do
  if parse_common_arg "$@"; then
    shift "$PARSE_COMMON_CONSUMED"
    continue
  fi

  case "$1" in
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

require_cmd aws
require_cmd jq
resolve_deploy_config
load_parameter_overrides
set_parameter_override BackendDesiredCount 0
set_parameter_override EnableFrontendRuntime false

log "Resolved bootstrap values"
print_resolved_config
printf '  backend desired count: 0\n'
printf '  frontend runtime: false\n'

log "Validating CloudFormation template"
validate_template

log "Creating bootstrap change set"
create_change_set
change_set_result="$(wait_change_set_ready)"
if [[ "$change_set_result" == "NO_CHANGES" ]]; then
  log "No bootstrap changes to apply"
  delete_change_set
  exit 0
fi

print_change_set_summary

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry run complete"
  exit 0
fi

log "Executing bootstrap change set"
execute_change_set
wait_stack_terminal

if ! is_stack_success_status "$STACK_FINAL_STATUS"; then
  print_recent_stack_events
  die "Bootstrap failed with stack status ${STACK_FINAL_STATUS}"
fi

log "Bootstrap complete"
printf '  backend repository: %s\n' "$(stack_output BackendEcrRepositoryUri)"
printf '  frontend repository: %s\n' "$(stack_output FrontendEcrRepositoryUri)"
