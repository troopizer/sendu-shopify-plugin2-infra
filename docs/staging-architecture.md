# Staging AWS Architecture Plan

This document defines a simple and solid staging architecture for:

- Frontend: React app served by Lambda + API Gateway (container image)
- Backend: Ruby on Rails container on ECS Fargate

It is implemented in `template.staging.yaml`.

## Goals

- Keep `RDS PostgreSQL` private in VPC subnets
- Deploy backend from `ECR` with the `latest` channel
- Deploy frontend Lambda image from `ECR` with the `latest` channel
- Preserve rollback safety using git tags and immutable metadata
- Keep the stack simple enough for staging operations

## High-Level Architecture

- `VPC` across 2 AZs with 3 subnet tiers:
  - Public: ALB + NAT
  - Private app: ECS Fargate tasks
  - Private DB: RDS PostgreSQL
- `ALB` (internet-facing) routes to ECS service tasks
- `RDS` is private (`PubliclyAccessible: false`) and accessible only from:
  - ECS security group
  - Client VPN CIDR (for developer DB access)
- Frontend runtime:
  - API Gateway HTTP API -> Lambda
  - Lambda serves static web files and proxies `/api/*` to backend ALB
  - Lambda image is stored in a dedicated frontend ECR repository

The staging template defines a fixed network layout (not parameterized):

- VPC: `10.30.0.0/16`
- Public subnets: `10.30.0.0/24`, `10.30.1.0/24`
- Private app subnets: `10.30.10.0/24`, `10.30.11.0/24`
- Private DB subnets: `10.30.20.0/24`, `10.30.21.0/24`

## Developer Access to Private RDS (No Bastion)

- Use `AWS Client VPN` (not modeled in this template yet)
- Developers connect from home/PC through VPN
- DB SG allows inbound 5432 from VPN client CIDR
- RDS remains private; no public endpoint exposure

## Deployment Policy (`latest` + git tags)

Use `latest` as the staging channel and git tags as release identity.

### Backend

- Build once, push both tags to ECR:
  - `:<git-tag>`
  - `:latest`
- ECS task definition references `:latest`
- Every deployment creates a new task definition revision
- Record deployment metadata:
  - git tag
  - resolved image digest
  - deploy timestamp

### Frontend

- Build Lambda image from tagged commit
- Push image to frontend ECR with both tags:
  - `:<git-tag>`
  - `:latest`
- CloudFormation parameter `FrontendImageTag` selects the deployed image tag
- Record deployment metadata:
  - git tag
  - resolved image digest
  - deploy timestamp

## Template Structure

`template.staging.yaml` includes:

- Networking: VPC, public/private subnets, route tables, IGW, NAT
- Security groups: ALB, ECS service, DB
- Backend: ECR repo, ECS cluster, task definition, service, ALB
- Database: Secrets Manager secret, subnet group, PostgreSQL RDS instance
- Frontend: dedicated ECR repo, Lambda (container image), API Gateway HTTP API

## CFN Parameter Resolution

Parameter handling is split by responsibility:

- Derived in template (not parameters):
  - fixed staging CIDRs for VPC/subnets
  - `RAILS_ENV` derived from `EnvironmentName`
- Stable non-secret environment config (committed):
  - naming (`ProjectName`, `EnvironmentName`)
  - capacity and tuning (`BackendCpu`, `BackendMemory`, `DatabaseInstanceClass`, etc.)
- Secrets Manager references (committed, non-secret):
  - `UpstreamApiTokenSecretId`
  - `ShopifyApiKeySecretId`
- Release-time deployment inputs (pipeline/local override):
  - `BackendImageTag`
  - `FrontendImageTag`

The template resolves frontend app secrets with dynamic references:

- `{{resolve:secretsmanager:${UpstreamApiTokenSecretId}:SecretString}}`
- `{{resolve:secretsmanager:${ShopifyApiKeySecretId}:SecretString}}`

This keeps plaintext secrets out of committed parameter files.

## Backend Env Var Contract

Backend ECS env vars are intentionally split by source:

- From CFN parameters (developer-controlled):
  - `RAILS_ENV` -> `EnvironmentName`
  - `PORT` -> `BackendContainerPort`
  - `DB_NAME` -> `DatabaseName`
- From AWS resources (derived):
  - `DB_HOST` -> `Database.Endpoint.Address`
- From Secrets Manager (`DatabaseCredentialsSecret`):
  - `DB_PORT` -> `port`
  - `DB_USER` -> `username`
  - `DB_PASSWORD` -> `password`

## Bootstrap Notes

The frontend ECR repository is created by this stack, and the Lambda image must exist in ECR before stack creation/update that includes the Lambda function.

Use `EnableFrontendRuntime=false` for first-time bootstrap to create infra and ECR without creating the frontend Lambda/API resources.

Bootstrap flow:

1. Deploy with `EnableFrontendRuntime=false`.
2. Build and push frontend image tag to the `FrontendEcrRepository`.
3. Re-deploy with `EnableFrontendRuntime=true FrontendImageTag=<tag>`.

Important: setting `EnableFrontendRuntime=false` on an existing stack will remove frontend runtime resources managed by that condition.

## Deploy From Any Machine

To deploy from local or CI, the machine only needs:

- AWS credentials/profile with CloudFormation permissions
- ECR push permissions for app images
- permission to read referenced secrets (`secretsmanager:GetSecretValue`) during stack updates
- the non-secret parameter file (`parameters.staging.json`)

Recommended flow:

1. Keep committed env parameters non-secret (including secret IDs/ARNs only).
2. Build and push backend/frontend images.
3. Override release-time image tags at deploy (`BackendImageTag`, `FrontendImageTag`).
4. Run CloudFormation deploy with merged parameter overrides.

### Frontend Delivery Ownership

- `sendu-shopify-plugin2-infra` is the single owner of CloudFormation resources.
- `sendu-shopify-plugin2-frontend` only builds and pushes the frontend Lambda image.
- Frontend release flow:
  1. Build and push frontend image tags (`:<git-tag>` and `:latest`) to `FrontendEcrRepository`.
  2. Deploy/update this stack with `FrontendImageTag=<git-tag>`.

Example (after image push):

```bash
aws cloudformation deploy \
  --stack-name sendu-plugin2-staging \
  --template-file template.staging.yaml \
  --parameter-overrides file://parameters.staging.json EnableFrontendRuntime=true FrontendImageTag=v2026.04.12 \
  --capabilities CAPABILITY_NAMED_IAM
```

Example bootstrap deploy (first run, before frontend image exists):

```bash
aws cloudformation deploy \
  --stack-name sendu-plugin2-staging \
  --template-file template.staging.yaml \
  --parameter-overrides file://parameters.staging.json EnableFrontendRuntime=false \
  --capabilities CAPABILITY_NAMED_IAM
```

Example image tag validation before enabling frontend runtime:

```bash
aws ecr describe-images \
  --repository-name sendu-plugin2-staging-frontend \
  --image-ids imageTag=v2026.04.12 \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null
```

Example validation + deploy (local or CI):

```bash
AWS_PROFILE=staging
AWS_REGION=eu-west-1

aws secretsmanager describe-secret \
  --secret-id sendu/staging/upstream-api-token \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null

aws secretsmanager describe-secret \
  --secret-id sendu/staging/shopify-api-key \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null

aws cloudformation deploy \
  --stack-name sendu-plugin2-staging \
  --template-file template.staging.yaml \
  --parameter-overrides file://parameters.staging.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

## Operational Defaults

- ECS desired count: `1`
- Backend image tag: `latest`
- Frontend image tag: `latest`
- RDS class: `db.t4g.small`
- RDS backup retention: `7` days
- Frontend Lambda log level: `info`

## Security Baseline

- No secrets in committed parameter files
- Commit secret identifiers only (name/ARN), never secret values
- RDS encryption enabled
- ECR scan on push for backend and frontend repositories
- CloudWatch logs for ECS and Lambda with retention
- Least-privilege IAM roles for ECS and Lambda
