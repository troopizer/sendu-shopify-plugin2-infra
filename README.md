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
- Shared files: `shared/template.yaml`, `shared/.env.example`

Both environments must use the same AWS region configured in their environment files. The shared stack owns the ECR repositories consumed by staging and prod.

The shared stack must be deployed before either environment because both environment stacks import its ECR exports.

Start from the matching environment example:

```bash
cp staging/.env.example staging/.env
```

For prod:

```bash
cp prod/.env.example prod/.env
```

## First-Time Bootstrap

Deploy the shared ECR stack once before bootstrapping either environment:

```bash
cp shared/.env.example shared/.env
make shared-bootstrap
```

Migrate existing images from the old prod repositories before updating the prod stack:

```bash
make ecr-migrate \
  SOURCE_STACK=sendu-plugin2-prod \
  SOURCE_REGION=<source-region> \
  BACKEND_VERSION=<backend-tag> \
  FRONTEND_VERSION=<frontend-tag>
```

For an old staging stack in another region, run the migration with its source stack and region explicitly.

After migration, update the existing prod stack so it imports the shared repositories:

```bash
make plan prod VERSION=<verified-tag>
make deploy prod VERSION=<verified-tag>
make ecr-verify VERSION=<verified-tag>
```

For the staging regional migration, create the new stack in the configured shared region after the shared stack and prod exports are available:

```bash
make bootstrap staging
make deploy staging VERSION=<verified-tag>
```

Then bootstrap the environment stacks. Each environment bootstrap deploys with `BackendDesiredCount=0` and `EnableFrontendRuntime=false`, creating stable frontend shell resources without starting app runtimes that require images.

For prod:

```bash
cp prod/.env.example prod/.env
make bootstrap prod
```

For staging:

```bash
cp staging/.env.example staging/.env
make bootstrap staging
```

Verify the shared repositories and Lambda pull policy:

```bash
make ecr-verify
make ecr-verify BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
```

## Normal Deploy

This repo does not build or push Docker images. Backend and frontend images must already exist in the shared ECR repositories before deployment.

Deploy with the Makefile:

```bash
make deploy staging VERSION=<image-tag>
```

If no image version is provided, deployment selects the most recently pushed tagged backend and frontend images from shared ECR independently.

For prod:

```bash
make deploy prod VERSION=<image-tag>
```

If backend and frontend image tags differ:

```bash
make deploy prod BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>
```

The deploy script checks ECR before updating CloudFormation and fails if a required image tag is missing.

The selected image tags must already exist in the shared ECR repositories. Without explicit tags, the deploy script resolves the most recently pushed tagged image for each repository. The staging and prod stacks expose the same repository outputs to the image validation scripts.
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
openssl rand -hex 64 | ./scripts/secrets set SECRET_KEY_BASE
./scripts/secrets set SHOPIFY_APP_HOST
./scripts/secrets set SHOPIFY_FRONTEND_URL
./scripts/secrets set UPSTREAM_API_TOKEN
```

The secret name comes from `AppSecretsSecretId` in the selected parameters file.

For prod:

```bash
./scripts/secrets --environment prod init
./scripts/secrets --environment prod set SHOPIFY_API_KEY
./scripts/secrets --environment prod set SHOPIFY_API_SECRET
./scripts/secrets --environment prod set RAILS_MASTER_KEY
openssl rand -hex 64 | ./scripts/secrets --environment prod set SECRET_KEY_BASE
./scripts/secrets --environment prod set SHOPIFY_APP_HOST
./scripts/secrets --environment prod set SHOPIFY_FRONTEND_URL
./scripts/secrets --environment prod set UPSTREAM_API_TOKEN
```

The backend receives its database username and password directly from the RDS master-credentials secret. Do not copy them into the shared app secret.

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
