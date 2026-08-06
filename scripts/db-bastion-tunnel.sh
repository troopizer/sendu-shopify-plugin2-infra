#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="sendu-plugin2-staging"
INSTANCE_ID="${BASTION_INSTANCE_ID:-}"
DB_HOST="${DB_HOST:-}"
AWS_PROFILE_NAME="${AWS_PROFILE:-staging}"
AWS_REGION_NAME="${AWS_REGION:-eu-west-1}"
LOCAL_PORT="5432"
REMOTE_PORT="5432"
CLEANED_UP="false"

usage() {
  cat <<USAGE
Usage: $0 [options]

Open an SSM port-forwarding session through the on-demand EC2 bastion.
The bastion is stopped automatically when the script exits or receives Ctrl+C.

Options:
  --instance-id ID       Bastion EC2 instance ID. Default: CloudFormation BastionInstanceId output.
  --db-host HOST         RDS endpoint hostname. Default: CloudFormation DatabaseEndpointAddress output.
  --profile PROFILE      AWS profile. Default: ${AWS_PROFILE_NAME}
  --region REGION        AWS region. Default: ${AWS_REGION_NAME}
  --help                 Show this help.

Environment overrides are also supported:
  BASTION_INSTANCE_ID, DB_HOST, AWS_PROFILE, AWS_REGION
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id)
      INSTANCE_ID="${2:?Missing value for --instance-id}"
      shift 2
      ;;
    --db-host)
      DB_HOST="${2:?Missing value for --db-host}"
      shift 2
      ;;
    --profile)
      AWS_PROFILE_NAME="${2:?Missing value for --profile}"
      shift 2
      ;;
    --region)
      AWS_REGION_NAME="${2:?Missing value for --region}"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

aws_cli() {
  aws "$@" --profile "$AWS_PROFILE_NAME" --region "$AWS_REGION_NAME"
}

stack_output() {
  local output_key="$1"

  aws_cli cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text
}

cleanup() {
  if [[ "$CLEANED_UP" == "false" && -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]]; then
    echo "Stopping bastion ${INSTANCE_ID}..."
    CLEANED_UP="true"
    aws_cli ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null || true
  fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "$INSTANCE_ID" ]]; then
  INSTANCE_ID="$(stack_output BastionInstanceId)"
fi

if [[ -z "$DB_HOST" ]]; then
  DB_HOST="$(stack_output DatabaseEndpointAddress)"
fi

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "Could not resolve bastion instance ID. Pass --instance-id." >&2
  exit 1
fi

if [[ -z "$DB_HOST" || "$DB_HOST" == "None" ]]; then
  echo "Could not resolve database host. Pass --db-host." >&2
  exit 1
fi

STATE="$(aws_cli ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query "Reservations[0].Instances[0].State.Name" \
  --output text)"

if [[ "$STATE" != "running" ]]; then
  echo "Starting bastion ${INSTANCE_ID}..."
  aws_cli ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null

  aws_cli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi

echo "Waiting for SSM connection on ${INSTANCE_ID}..."
until [[ "$(aws_cli ssm get-connection-status --target "$INSTANCE_ID" --query Status --output text 2>/dev/null || true)" == "connected" ]]; do
  sleep 5
done

echo "Opening DB tunnel: localhost:${LOCAL_PORT} -> ${DB_HOST}:${REMOTE_PORT}"
aws_cli ssm start-session \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"${DB_HOST}\"],\"portNumber\":[\"${REMOTE_PORT}\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}"
