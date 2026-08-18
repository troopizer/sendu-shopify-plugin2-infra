---
name: deploy-sendu-infra
description: Use when deploying the Sendu Shopify plugin AWS infra repo to staging or prod.
---

# Deploy Sendu Infra

Use the repo Makefile targets as the primary interface. For non-deploy operations and extra options, use `make help`, `./scripts/deploy.sh --help`, `./scripts/monitor-deploy.sh --help`, or `./scripts/bootstrap.sh --help`.

Do not use `scripts/deploy-stack.sh` or `scripts/release-all.sh`; both are deprecated and intentionally fail.

## Deploy

Before deploying, confirm the target environment: `staging` or `prod`.

This infra repo does not build or push images. Backend and frontend images must already exist in the selected environment's ECR repositories.

Before deploying, determine image tags.

If the user has not provided image tags, ask them to choose one:

1. Deploy latest backend and frontend images

```bash
VERSION=latest
```

2. Choose backend and frontend versions separately

```bash
BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
```

If the user provides a single tag, use it for both images:

```bash
VERSION=<image-tag>
```

If the user provides separate backend/frontend tags, preserve them exactly:

```bash
BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
```

Do not guess tags other than `latest`; ask first when the intended version is unclear.

Deploy and monitor:

```bash
make deploy staging VERSION=<image-tag>
make deploy prod VERSION=<image-tag>
```

Deploy latest backend and frontend images:

```bash
make deploy staging VERSION=latest
make deploy prod VERSION=latest
```

Deploy with different backend/frontend tags:

```bash
make deploy staging BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
make deploy prod BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
```
