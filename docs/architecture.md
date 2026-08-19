# AWS Architecture Plan

This document describes this repository's organization for staging and prod architecture:

- Frontend: React app served by Lambda + API Gateway (container image)
- Backend: Ruby on Rails container on ECS Fargate

It is implemented with shared files under `shared/` and environment files under `staging/` and `prod/`.

## Environment Files

- Staging parameters: `staging/parameters.json`
- Staging template: `staging/template.yaml`
- Staging env example: `staging/.env.example`
- Prod parameters: `prod/parameters.json`
- Prod template: `prod/template.yaml`
- Prod env example: `prod/.env.example`
- Shared template: `shared/template.yaml`
- Shared env example: `shared/.env.example`

The shared template owns the ECR repositories. Use `make shared-bootstrap` to deploy it and `make ecr-migrate` to copy existing image manifests into the shared repositories before environment deployment.

Scripts resolve the selected environment with `--environment <name>`. The Makefile passes this from `ENV=staging` or `ENV=prod`.

Both environments run in the same AWS region configured in their environment files. The `shared/` stack owns the backend and frontend ECR repositories, and both environment stacks import their exported repository URIs.

Deploy the shared stack before either environment. Use `make ecr-verify` to verify repository configuration, Lambda pull permissions, and optional image tags.

## Deployment Lifecycle

- Use the Makefile as the primary deployment interface. For the full command surface, run `make help` or `./scripts/deploy.sh --help`.
- Choose the environment first: `staging` or `prod`.
- Choose image tags before deploying when pinning a release. Use `VERSION=<tag>` when backend and frontend use the same image tag, or `BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>` when they differ.
- If no tag is provided, deployment selects the most recently pushed tagged image from each shared ECR repository independently.
- Normal deployment runs with `make deploy <environment> VERSION=<tag>`.
- Deployment with separate image tags runs with `make deploy <environment> BACKEND_VERSION=<backend-tag> FRONTEND_VERSION=<frontend-tag>`.
- `scripts/deploy.sh` validates the environment template, confirms the target stack exists, checks that the stack is in a terminal CloudFormation state, checks the requested ECR image tags, creates a CloudFormation change set, executes it, and monitors the deployment.
- Normal deploy overrides image tags and enables the frontend runtime, but leaves `BackendDesiredCount` to the selected environment parameters. Deploy `shared/template.yaml` first to create the shared ECR repositories, then bootstrap the environment stacks with `BackendDesiredCount=0`.
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
- Local/CI defaults: copy `<environment>/.env.example` to `<environment>/.env`, or export values manually
- Secrets: referenced by `AppSecretsSecretId`; secret values are not committed

## Operational Defaults

- ECS desired count: from the selected environment parameters; bootstrap overrides it to `0`
- Backend image tag: `latest` unless overridden at deployment time
- Frontend image tag: `latest` unless overridden at deployment time
- RDS class: `db.t4g.small`
- RDS backup retention: `7` days
- Frontend Lambda log level: staging `debug`, prod `info`
