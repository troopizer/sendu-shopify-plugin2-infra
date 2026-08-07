# Sendu AWS Infra

CloudFormation infrastructure for staging deployment:

- Backend: Rails container on ECS Fargate behind an ALB
- Frontend: Vite/React static app served by a Lambda container behind API Gateway
- Shared AWS resources: VPC, RDS PostgreSQL, ECR repositories, Secrets Manager, SSM bastion

## First-Time Bootstrap

The ECR repositories are created by this stack, so bootstrap once before pushing images:

```bash
cp .env.example .env
./scripts/deploy-stack.sh --bootstrap
```

This deploys with `BackendDesiredCount=0` and `EnableFrontendRuntime=false`, creating the repositories without starting app runtimes that require images.

## Normal Deploy

The most-used deployment path builds and pushes both images, then updates the stack. If `--image-tag` is omitted, the current git commit SHA is used as the image tag:

```bash
./scripts/release-all.sh
```

The script passes `VITE_API_BASE_URL` to the frontend image build automatically. It uses `--api-base-url` when provided, then `VITE_API_BASE_URL` from the environment, then the stack `FrontendApiBaseUrl` output, and finally `/api` as a same-origin fallback.

Use an explicit tag when releasing a named version:

```bash
./scripts/release-all.sh --image-tag <git-tag>
```

After backend and frontend images are already pushed, update only the stack with both release tags:

```bash
./scripts/deploy-stack.sh \
  --backend-image-tag <git-tag> \
  --frontend-image-tag <git-tag> \
  --enable-frontend-runtime true \
  --backend-desired-count 1
```

Use explicit AWS overrides when needed:

```bash
./scripts/deploy-stack.sh \
  --profile <aws-profile> \
  --region <aws-region> \
  --stack-name sendu-plugin2-staging \
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

The secret name comes from `AppSecretsSecretId` in `parameters.staging.json`.

## Validation

Print the CloudFormation deploy command without running it:

```bash
./scripts/deploy-stack.sh --dry-run
```
