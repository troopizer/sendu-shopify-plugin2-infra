#!/usr/bin/env bash

set -euo pipefail

cat >&2 <<'EOF'
ERROR: scripts/deploy-stack.sh is deprecated.

This infra repository now uses the monitored deployment lifecycle.

Use:

  make deploy staging VERSION=<image-tag>
  make deploy prod VERSION=<image-tag>
  make plan prod VERSION=<image-tag>
  make monitor prod VERSION=<image-tag>
  make bootstrap staging
  make bootstrap prod

If backend and frontend tags differ:

  make deploy prod BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>

Direct script equivalents:

  ./scripts/deploy.sh --environment prod --version <image-tag>
  ./scripts/bootstrap.sh --environment prod
EOF

exit 1
