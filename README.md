# Sendu AWS Infra

CloudFormation infrastructure for staging and prod deployments:

- Backend: Rails container on ECS Fargate behind an ALB
- Frontend: Vite/React static app served by a Lambda container behind API Gateway
- Shared AWS resources: VPC, RDS PostgreSQL, ECR repositories, Secrets Manager, SSM bastion

Architecture docs:

- Markdown summary: `docs/architecture.md`
- HTML document with Mermaid diagrams: `docs/architecture.html`

## Environment Config

Each environment has its own CloudFormation template and parameter file:

- Staging files: `staging/template.yaml`, `staging/parameters.json`, `staging/.env.example`
- Prod files: `prod/template.yaml`, `prod/parameters.json`, `prod/.env.example`

Start from the matching env example:

```bash
cp staging/.env.example .env
```

For prod:

```bash
cp prod/.env.example .env
```

## First-Time Bootstrap

The ECR repositories are created by this stack, so bootstrap once before pushing images:

```bash
cp .env.example .env
make bootstrap staging
```

This deploys with `BackendDesiredCount=0` and `EnableFrontendRuntime=false`, creating the repositories and stable frontend shell resources without starting app runtimes that require images. The frontend API Gateway, API stage, Lambda role, and Lambda log group are created during bootstrap; only the image-dependent Lambda function, integration, routes, and invoke permission are deferred.

For prod, use `prod/.env.example` or pass explicit options:

```bash
make bootstrap prod
```

## Normal Deploy

This repo does not build or push Docker images. Backend and frontend images must already exist in the selected environment's ECR repositories before deployment.

Deploy with the Makefile:

```bash
make deploy staging VERSION=<image-tag>
```

For prod:

```bash
make deploy prod VERSION=<image-tag>
```

If backend and frontend image tags differ:

```bash
make deploy prod BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
```

The deploy script checks ECR before updating CloudFormation and fails if a required image tag is missing.
Deployment uses a CloudFormation change set, then monitors CloudFormation and ECS concurrently while the stack update is running. Monitoring stops when CloudFormation reaches a terminal state. After CloudFormation completes, it verifies ECS stability, ALB target health, Lambda status, and HTTP health checks.

Recent backend and Lambda warning/error log entries are reported as diagnostics, but log findings do not fail the deployment by themselves. Stopped ECS tasks during the deployment window are also reported with task details and recent task logs for diagnosis.

Deprecated deployment scripts:

- `scripts/deploy-stack.sh`
- `scripts/release-all.sh`

Both now fail with migration instructions. Use the Makefile targets or `scripts/deploy.sh` directly.

Preview a deployment without executing the change set:

```bash
make plan prod VERSION=<image-tag>
```

Check the current deployed runtime without deploying:

```bash
make monitor prod VERSION=<image-tag>
```

Direct script usage is also supported:

```bash
./scripts/deploy.sh \
  --backend-image-tag <git-tag> \
  --frontend-image-tag <git-tag> \
  --environment staging
```

Use explicit AWS overrides when needed:

```bash
./scripts/deploy.sh \
  --profile <aws-profile> \
  --region <aws-region> \
  --environment staging \
  --template-file staging/template.yaml \
  --backend-image-tag <git-tag> \
  --frontend-image-tag <git-tag>
```

## Secrets

Initialize and maintain the shared app secret with:

```bash
./scripts/secrets init
./scripts/secrets set SHOPIFY_API_KEY
./scripts/secrets set SHOPIFY_API_SECRET
./scripts/secrets set RAILS_MASTER_KEY
./scripts/secrets set SHOPIFY_APP_HOST
./scripts/secrets set SHOPIFY_FRONTEND_URL
./scripts/secrets set DB_USERNAME
./scripts/secrets set DB_PASSWORD
./scripts/secrets set UPSTREAM_API_TOKEN
```

The secret name comes from `AppSecretsSecretId` in the selected parameters file.

For prod:

```bash
./scripts/secrets --environment prod init
./scripts/secrets --environment prod set SHOPIFY_API_KEY
./scripts/secrets --environment prod set SHOPIFY_API_SECRET
./scripts/secrets --environment prod set RAILS_MASTER_KEY
./scripts/secrets --environment prod set SHOPIFY_APP_HOST
./scripts/secrets --environment prod set SHOPIFY_FRONTEND_URL
./scripts/secrets --environment prod set DB_USERNAME
./scripts/secrets --environment prod set DB_PASSWORD
./scripts/secrets --environment prod set UPSTREAM_API_TOKEN
```

## Validation

Print the CloudFormation deploy command without running it:

```bash
make dry-run staging VERSION=<image-tag>
```

Dry-run prod explicitly:

```bash
make dry-run prod VERSION=<image-tag>
```

Validate the selected environment template:

```bash
make validate staging
make validate prod
```
