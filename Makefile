SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

ENV_FROM_GOALS := $(firstword $(filter staging prod,$(MAKECMDGOALS)))
ENV ?= $(if $(ENV_FROM_GOALS),$(ENV_FROM_GOALS),staging)
VERSION ?= $(version)
BACKEND_VERSION ?= $(VERSION)
FRONTEND_VERSION ?= $(VERSION)
PROFILE ?=
REGION ?=
API_BASE_URL ?=
KEY ?=
LOCAL_PORT ?=
DRY_RUN ?=
SKIP_HTTP ?=

COMMON_ARGS = --environment $(ENV)
COMMON_ARGS += $(if $(PROFILE),--profile $(PROFILE),)
COMMON_ARGS += $(if $(REGION),--region $(REGION),)

DRY_RUN_ARG = $(if $(filter 1 true yes,$(DRY_RUN)),--dry-run,)

STACK_ARGS = $(COMMON_ARGS)
STACK_ARGS += $(if $(BACKEND_VERSION),--backend-image-tag $(BACKEND_VERSION),)
STACK_ARGS += $(if $(FRONTEND_VERSION),--frontend-image-tag $(FRONTEND_VERSION),)
STACK_ARGS += $(if $(filter 1 true yes,$(SKIP_HTTP)),--skip-http,)
STACK_ARGS += $(DRY_RUN_ARG)

SECRETS_ARGS = --environment $(ENV)
SECRETS_ARGS += $(if $(PROFILE),--profile $(PROFILE),)

TUNNEL_ARGS = $(COMMON_ARGS)
TUNNEL_ARGS += $(if $(LOCAL_PORT),--local-port $(LOCAL_PORT),)

VALIDATE_ARGS = $(if $(PROFILE),--profile $(PROFILE),)
VALIDATE_ARGS += $(if $(REGION),--region $(REGION),)

.PHONY: help check-env check-version staging prod deploy plan monitor bootstrap dry-run validate secrets-init secrets-ls secrets-get secrets-set db-tunnel

help:
	@printf '%s\n' \
		'Usage:' \
		'  make deploy staging VERSION=1.1.8' \
		'  make deploy prod VERSION=1.0.62' \
		'  make bootstrap ENV=prod' \
		'  make plan prod VERSION=1.0.62' \
		'  make monitor prod VERSION=1.0.62' \
		'  make dry-run prod VERSION=1.0.62' \
		'  make validate prod' \
		'' \
		'Targets:' \
		'  deploy        Deploy CloudFormation and monitor CloudFormation, ECS, Lambda, logs, and health' \
		'  plan          Create and print a CloudFormation change set without executing it' \
		'  monitor       Check current CloudFormation, ECR, ECS, ALB, Lambda, logs, and health' \
		'  bootstrap     First-time stack deploy with runtimes disabled for initial ECR creation' \
		'  dry-run       Print deployment AWS commands without executing them' \
		'  validate      Validate the selected environment CloudFormation template' \
		'  secrets-init  Create the environment app secret' \
		'  secrets-ls    List keys in the environment app secret' \
		'  secrets-get   Get one secret key, requires KEY=<name>' \
		'  secrets-set   Set one secret key, requires KEY=<name>' \
		'  db-tunnel     Open an SSM tunnel to the environment database' \
		'' \
		'Variables:' \
		'  ENV=staging|prod, VERSION=<image-tag>, BACKEND_VERSION=<tag>, FRONTEND_VERSION=<tag>' \
		'  PROFILE=<aws-profile>, REGION=<aws-region>, DRY_RUN=1, SKIP_HTTP=1, KEY=<secret-key>, LOCAL_PORT=<port>'

check-env:
	@case '$(ENV)' in \
		staging|prod) ;; \
		*) printf 'ENV must be staging or prod, got: %s\n' '$(ENV)' >&2; exit 2 ;; \
	esac

check-version:
	@test -n '$(BACKEND_VERSION)' || { printf 'VERSION or BACKEND_VERSION is required. Example: make deploy prod VERSION=1.0.62\n' >&2; exit 2; }
	@test -n '$(FRONTEND_VERSION)' || { printf 'VERSION or FRONTEND_VERSION is required. Example: make deploy prod VERSION=1.0.62\n' >&2; exit 2; }

deploy: check-env check-version
	./scripts/deploy.sh $(STACK_ARGS)

plan: check-env check-version
	./scripts/deploy.sh $(STACK_ARGS) --plan

monitor: check-env check-version
	./scripts/monitor-deploy.sh $(STACK_ARGS)

bootstrap: check-env
	./scripts/bootstrap.sh $(COMMON_ARGS) $(DRY_RUN_ARG)

dry-run: DRY_RUN := true
dry-run: deploy

validate: check-env
	aws cloudformation validate-template --template-body file://$(ENV)/template.yaml $(VALIDATE_ARGS)

secrets-init: check-env
	./scripts/secrets $(SECRETS_ARGS) init

secrets-ls: check-env
	./scripts/secrets $(SECRETS_ARGS) ls

secrets-get: check-env
	@test -n '$(KEY)' || { printf 'KEY is required. Example: make secrets-get prod KEY=DB_USERNAME\n' >&2; exit 2; }
	./scripts/secrets $(SECRETS_ARGS) get '$(KEY)'

secrets-set: check-env
	@test -n '$(KEY)' || { printf 'KEY is required. Example: make secrets-set prod KEY=DB_USERNAME\n' >&2; exit 2; }
	./scripts/secrets $(SECRETS_ARGS) set '$(KEY)'

db-tunnel: check-env
	./scripts/db-bastion-tunnel.sh $(TUNNEL_ARGS)

staging prod:
	@:
