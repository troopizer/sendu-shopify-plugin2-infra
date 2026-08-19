# AWS Architecture Plan

This document describes this repository's organization for staging and prod architecture:

- Frontend: React app served by Lambda + API Gateway (container image)
- Backend: Ruby on Rails container on ECS Fargate

It is implemented with separate environment files under `staging/` and `prod/`.

## Environment Files

- Staging parameters: `staging/parameters.json`
- Staging template: `staging/template.yaml`
- Staging env example: `staging/.env.example`
- Prod parameters: `prod/parameters.json`
- Prod template: `prod/template.yaml`
- Prod env example: `prod/.env.example`

Scripts resolve the selected environment with `--environment <name>` or `DEPLOY_ENVIRONMENT`.

## Deployment Lifecycle

- Use the Makefile as the primary deployment interface. For the full command surface, run `make help` or `./scripts/deploy.sh --help`.
- Choose the environment first: `staging` or `prod`.
- Choose image tags before deploying. Use `VERSION=<tag>` when backend and frontend use the same image tag, or `BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>` when they differ.
- If no tag is provided, decide explicitly between deploying `VERSION=latest` for both images or selecting backend and frontend versions separately. Do not guess version tags other than `latest`.
- Normal deployment runs with `make deploy <environment> VERSION=<tag>`.
- Deployment with separate image tags runs with `make deploy <environment> BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>`.
- `scripts/deploy.sh` validates the environment template, checks the requested ECR image tags, creates a CloudFormation change set, executes it, and monitors the deployment.
- CloudFormation stack events and ECS service state are monitored concurrently while the stack update is running. Watchers stop when CloudFormation reaches a terminal state.
- After CloudFormation completes, deployment verifies ECS stability, ALB target health, Lambda update status, and HTTP health checks.
- Failed ECS tasks, recent backend warnings/errors, and recent Lambda warnings/errors are printed as diagnostics. These diagnostics do not fail deployment by themselves.
- `make plan <environment> VERSION=<tag>` creates and prints a change set, then deletes it without executing.
- `make monitor <environment> VERSION=<tag>` checks the current deployed runtime without deploying and fails if the CloudFormation stack is not in a healthy terminal state.
- `scripts/deploy-stack.sh` and `scripts/release-all.sh` are deprecated compatibility stubs. They do not deploy.

## Bootstrap Frontend Guard

`EnableFrontendRuntime=false` is used during first-time bootstrap so CloudFormation does not create resources that require a frontend Lambda image tag to already exist in ECR.

Only these frontend resources are conditionally skipped:

- `FrontendLambdaFunction`
- `FrontendHttpApiIntegration`
- `FrontendHttpApiProxyRoute`
- `FrontendHttpApiRootRoute`
- `FrontendLambdaInvokePermission`

These stable frontend shell resources are created and preserved even when `EnableFrontendRuntime=false`:

- `FrontendLambdaExecutionRole`
- `FrontendLambdaLogGroup`
- `FrontendHttpApi`
- `FrontendHttpApiStage`
- `FrontendApiUrl` and `FrontendApiBaseUrl` outputs

## Deployment Inputs

- Environment CloudFormation template: `<environment>/template.yaml`
- Non-secret environment config: `<environment>/parameters.json`
- Local/CI defaults: `<environment>/.env.example` copied to `.env` or exported manually
- Secrets: referenced by `AppSecretsSecretId`; secret values are not committed

## Operational Defaults

- ECS desired count: `1`
- Backend image tag: `latest` unless overridden at deployment time
- Frontend image tag: `latest` unless overridden at deployment time
- RDS class: `db.t4g.small`
- RDS backup retention: `7` days
- Frontend Lambda log level: staging `debug`, prod `info`
