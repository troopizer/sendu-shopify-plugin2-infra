# Staging AWS Architecture Plan

This document defines a simple and solid staging architecture for:

- Frontend: React app served by Lambda + API Gateway
- Backend: Ruby on Rails container on ECS Fargate

It is implemented in `template.staging.yaml`.

## Goals

- Keep `RDS PostgreSQL` private in VPC subnets
- Deploy backend from `ECR` with the `latest` channel
- Deploy frontend Lambda artifact from `S3` with the `latest` channel
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
- Frontend artifacts are stored in S3 with versioning enabled

The staging template defines a fixed network layout (not parameterized):

- VPC: `10.30.0.0/16`
- Public subnets: `10.30.0.0/24`, `10.30.1.0/24`
- Private app subnets: `10.30.10.0/24`, `10.30.11.0/24`
- Private DB subnets: `10.30.20.0/24`, `10.30.21.0/24`

## Developer Access to Private RDS (No Bastion)

- Use `AWS Client VPN` (optional resources are included in the template)
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

- Build Lambda artifact zip from tagged commit
- Upload immutable object path:
  - `releases/<git-tag>/lambda.zip`
- Promote/copy to channel path:
  - `latest/lambda.zip`
- Pass S3 object version to CloudFormation (`FrontendArtifactObjectVersion`) so updates are deterministic
- Record deployment metadata:
  - git tag
  - S3 object version
  - deploy timestamp

## Template Structure

`template.staging.yaml` includes:

- Networking: VPC, public/private subnets, route tables, IGW, NAT
- Security groups: ALB, ECS service, DB, optional VPN endpoint
- Backend: ECR repo, ECS cluster, task definition, service, ALB
- Database: Secrets Manager secret, subnet group, PostgreSQL RDS instance
- Frontend: optional artifact bucket, Lambda, API Gateway HTTP API
- Optional Client VPN resources

## Bootstrap Notes

If you create a new artifact bucket in this same stack, the Lambda artifact must exist in S3 before Lambda can be created.

For first-time bootstrap, use one of these paths:

1. Set `DeployFrontendRuntime=false`, create stack, upload artifact, then update stack with `DeployFrontendRuntime=true`.
2. Set `CreateArtifactBucket=false` and point to an existing bucket that already has the artifact.

## Operational Defaults

- ECS desired count: `1`
- Backend image tag: `latest`
- RDS class: `db.t4g.small`
- RDS backup retention: `7` days
- Frontend Lambda log level: `info`

## Security Baseline

- No secrets in committed parameter files
- RDS and artifact bucket encryption enabled
- CloudWatch logs for ECS and Lambda with retention
- Least-privilege IAM roles for ECS and Lambda
