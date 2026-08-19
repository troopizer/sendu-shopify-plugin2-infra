#!/usr/bin/env bash

set -euo pipefail

cat >&2 <<'EOF'
ERROR: scripts/release-all.sh is deprecated.

This infra repository no longer builds or pushes Docker images.
Build and push backend/frontend images from their owning repositories, then deploy infra with:

  make deploy staging VERSION=<image-tag>
  make deploy prod VERSION=<image-tag>

If backend and frontend tags differ:

  make deploy prod BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
EOF

exit 1
