#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Must-set variables
# -----------------------------------------------------------------------------

WEBSITE_HOSTNAME="${WEBSITE_HOSTNAME:-xlentors.dev}"

GCLOUD_PROJECT_ID="${GCLOUD_PROJECT_ID:-xlentors-dev}"
GCLOUD_REGION="${GCLOUD_REGION:-us-central1}"
GCLOUD_SERVICE_NAME="${GCLOUD_SERVICE_NAME:-xlentors-dev}"

GITHUB_REPO_URI="${GITHUB_REPO_URI:-https://github.com/Xlentors/xlentors-dev.git}"

# -----------------------------------------------------------------------------
# Defaulted settings
# -----------------------------------------------------------------------------

BASE_SERVICE_DNS_NAME="${BASE_SERVICE_DNS_NAME:-$WEBSITE_HOSTNAME}"
BASE_ARTIFACT_REPO_APP="${BASE_ARTIFACT_REPO_APP:-${GCLOUD_SERVICE_NAME}-app}"
BASE_AUTO_TRIGGER_NAME="${BASE_AUTO_TRIGGER_NAME:-${GCLOUD_SERVICE_NAME}-cloudrun-deploy}"
BASE_MANUAL_TRIGGER_NAME="${BASE_MANUAL_TRIGGER_NAME:-${GCLOUD_SERVICE_NAME}-cloudrun-deploy-manual}"
BASE_DEPLOY_BRANCH="${BASE_DEPLOY_BRANCH:-main}"

TEST_ENV_PREFIX="${TEST_ENV_PREFIX:-test-}"
TEST_SERVICE_DNS_NAME="${TEST_SERVICE_DNS_NAME:-${TEST_ENV_PREFIX}${WEBSITE_HOSTNAME}}"
TEST_ARTIFACT_REPO_APP="${TEST_ARTIFACT_REPO_APP:-${TEST_ENV_PREFIX}${GCLOUD_SERVICE_NAME}-app}"

PORT="${PORT:-8080}"
CPU="${CPU:-1}"
MEMORY="${MEMORY:-512Mi}"
MIN_INSTANCES="${MIN_INSTANCES:-0}"
MAX_INSTANCES="${MAX_INSTANCES:-3}"
TIMEOUT="${TIMEOUT:-60s}"
CLOUD_RUN_INGRESS="${CLOUD_RUN_INGRESS:-all}"
IMAGE_NAME="${IMAGE_NAME:-$GCLOUD_SERVICE_NAME}"

CONNECTION_NAME="${CONNECTION_NAME:-${GCLOUD_PROJECT_ID}-github}"
REPOSITORY_NAME="${REPOSITORY_NAME:-$GCLOUD_SERVICE_NAME}"
BUILD_CONFIG_PATH="${BUILD_CONFIG_PATH:-cicd/cloudbuild-service.yaml}"
INCLUDED_FILES="${INCLUDED_FILES:-app.py,config.py,data/**,routes/**,scripts/**,services/**,static/**,templates/**,requirements.txt,.dockerignore,cicd/**}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-${GCLOUD_SERVICE_NAME}-deploy}"
RUNTIME_SERVICE_ACCOUNT_EMAIL="${RUNTIME_SERVICE_ACCOUNT_EMAIL:-}"
RECREATE_CLOUD_BUILD_TRIGGERS="${RECREATE_CLOUD_BUILD_TRIGGERS:-true}"

ENVIRONMENT="prod"
TARGET_SERVICE_NAME=""
TARGET_SERVICE_DNS_NAME=""
TARGET_ARTIFACT_REPO_APP=""
TARGET_AUTO_TRIGGER_NAME=""
TARGET_MANUAL_TRIGGER_NAME=""
EXPLICIT_BUILD_ID=""
DEPLOY_BRANCH=""
TAIL_BUILD_ID=""

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="$repo_root/cicd/.state"
connection_resource="projects/${GCLOUD_PROJECT_ID}/locations/${GCLOUD_REGION}/connections/${CONNECTION_NAME}"
repository_resource="${connection_resource}/repositories/${REPOSITORY_NAME}"

say() {
  printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  bash cicd/setupsvc.sh create [--test]
  bash cicd/setupsvc.sh deploy [--test [--branch <name>]]
  bash cicd/setupsvc.sh delete [--test]
  bash cicd/setupsvc.sh status [--test]
  bash cicd/setupsvc.sh chkdomain [--test]
  bash cicd/setupsvc.sh chkbuild [--test] [--build-id <id>]
  bash cicd/setupsvc.sh tailbuild <build-id>
  bash cicd/setupsvc.sh lsbuild
  bash cicd/setupsvc.sh chksvc [--test]
  bash cicd/setupsvc.sh logsvc [--test]

Commands:
  create         Create the GCP artifacts needed before deployment.
  deploy         Run the Cloud Build-triggered deployment flow.
  delete         Delete the service resources and env-specific artifacts.
  status         Show artifact, service, and domain mapping status.
  chkdomain      Show Cloud Run domain mapping status and DNS records.
  chkbuild       Print the Cloud Build log for the last or specified build.
  tailbuild      Stream the Cloud Build log for the specified build id.
  lsbuild        List the most recent Cloud Builds for the configured project.
  chksvc         Check that the Cloud Run service is reachable and healthy.
  logsvc         Stream Cloud Run service logs for the selected environment.

Deploy options:
  --test         Deploy the test environment through its Cloud Build trigger.
  --branch       Git branch to use for the deployment source.
EOF
}

COMMAND=""

parse_args() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 1
  fi

  case "$1" in
    create|deploy|delete|status|chkdomain|chkbuild|lsbuild|logsvc|chksvc)
      COMMAND="$1"
      shift
      ;;
    tailbuild)
      COMMAND="tailbuild"
      shift
      if [ "$#" -lt 1 ]; then
        say "tailbuild requires <build-id>"
        usage
        exit 1
      fi
      TAIL_BUILD_ID="$1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      say "Unknown command: $1"
      usage
      exit 1
      ;;
  esac

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --test)
        if [ "$COMMAND" = "tailbuild" ]; then
          say "tailbuild does not accept --test"
          exit 1
        fi
        ENVIRONMENT="test"
        ;;
      --branch)
        if [ "$#" -lt 2 ]; then
          say "--branch requires a value"
          exit 1
        fi
        DEPLOY_BRANCH="$2"
        shift
        ;;
      --branch=*)
        DEPLOY_BRANCH="${1#--branch=}"
        ;;
      --build-id)
        if [ "$#" -lt 2 ]; then
          say "--build-id requires a value"
          exit 1
        fi
        EXPLICIT_BUILD_ID="$2"
        shift
        ;;
      --build-id=*)
        EXPLICIT_BUILD_ID="${1#--build-id=}"
        ;;
      --env)
        if [ "$#" -lt 2 ]; then
          say "--env requires a value"
          exit 1
        fi
        ENVIRONMENT="$2"
        shift
        ;;
      --env=*)
        ENVIRONMENT="${1#--env=}"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        say "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

configure_environment() {
  if [ "$ENVIRONMENT" = "test" ]; then
    TARGET_SERVICE_NAME="${TARGET_SERVICE_NAME:-${TEST_ENV_PREFIX}${GCLOUD_SERVICE_NAME}}"
    TARGET_SERVICE_DNS_NAME="${TARGET_SERVICE_DNS_NAME:-$TEST_SERVICE_DNS_NAME}"
    TARGET_ARTIFACT_REPO_APP="${TARGET_ARTIFACT_REPO_APP:-$TEST_ARTIFACT_REPO_APP}"
    TARGET_AUTO_TRIGGER_NAME="${TARGET_AUTO_TRIGGER_NAME:-${TEST_ENV_PREFIX}${BASE_AUTO_TRIGGER_NAME}}"
    TARGET_MANUAL_TRIGGER_NAME="${TARGET_MANUAL_TRIGGER_NAME:-${TEST_ENV_PREFIX}${BASE_MANUAL_TRIGGER_NAME}}"

    if [ "$COMMAND" = "deploy" ] && [ -z "$DEPLOY_BRANCH" ]; then
      say "--test requires --branch <name>"
      exit 1
    fi
  else
    TARGET_SERVICE_NAME="${TARGET_SERVICE_NAME:-$GCLOUD_SERVICE_NAME}"
    TARGET_SERVICE_DNS_NAME="${TARGET_SERVICE_DNS_NAME:-$BASE_SERVICE_DNS_NAME}"
    TARGET_ARTIFACT_REPO_APP="${TARGET_ARTIFACT_REPO_APP:-$BASE_ARTIFACT_REPO_APP}"
    TARGET_AUTO_TRIGGER_NAME="${TARGET_AUTO_TRIGGER_NAME:-$BASE_AUTO_TRIGGER_NAME}"
    TARGET_MANUAL_TRIGGER_NAME="${TARGET_MANUAL_TRIGGER_NAME:-$BASE_MANUAL_TRIGGER_NAME}"
    DEPLOY_BRANCH="${DEPLOY_BRANCH:-$BASE_DEPLOY_BRANCH}"
  fi

  if [ -z "$RUNTIME_SERVICE_ACCOUNT_EMAIL" ]; then
    RUNTIME_SERVICE_ACCOUNT_EMAIL="$(deploy_sa_email)"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "Missing required command: $1"
    exit 1
  fi
}

require_github_repo_uri() {
  if [ -n "$GITHUB_REPO_URI" ]; then
    return 0
  fi
  say "GITHUB_REPO_URI must be set for trigger-based deployments."
  say "  GITHUB_REPO_URI=https://github.com/Xlentors/xlentors-dev.git"
  exit 1
}

active_gcloud_account() {
  gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null | head -n 1
}

configured_gcloud_project() {
  gcloud config get-value project 2>/dev/null | tail -n 1
}

ensure_active_gcloud_project() {
  local configured_project=""
  configured_project="$(configured_gcloud_project)"
  if [ "$configured_project" = "$GCLOUD_PROJECT_ID" ]; then
    return 0
  fi
  say "Switching active gcloud project to ${GCLOUD_PROJECT_ID}"
  gcloud config set project "$GCLOUD_PROJECT_ID" >/dev/null
}

project_number() {
  gcloud projects describe "$GCLOUD_PROJECT_ID" --format='value(projectNumber)'
}

deploy_sa_email() {
  printf '%s@%s.iam.gserviceaccount.com' "$SERVICE_ACCOUNT_NAME" "$GCLOUD_PROJECT_ID"
}

deploy_sa_resource() {
  printf 'projects/%s/serviceAccounts/%s' "$GCLOUD_PROJECT_ID" "$(deploy_sa_email)"
}

cloud_build_service_agent_email() {
  printf 'service-%s@gcp-sa-cloudbuild.iam.gserviceaccount.com' "$(project_number)"
}

trigger_substitutions() {
  printf '_REGION=%s,_SERVICE_NAME=%s,_PORT=%s,_CPU=%s,_MEMORY=%s,_MIN_INSTANCES=%s,_MAX_INSTANCES=%s,_TIMEOUT=%s,_CLOUD_RUN_INGRESS=%s,_ARTIFACT_REPO_APP=%s,_IMAGE_NAME=%s,_RUNTIME_SERVICE_ACCOUNT_EMAIL=%s' \
    "$GCLOUD_REGION" "$TARGET_SERVICE_NAME" "$PORT" "$CPU" "$MEMORY" "$MIN_INSTANCES" "$MAX_INSTANCES" "$TIMEOUT" "$CLOUD_RUN_INGRESS" "$TARGET_ARTIFACT_REPO_APP" "$IMAGE_NAME" "$RUNTIME_SERVICE_ACCOUNT_EMAIL"
}

preflight_create() {
  local active_account=""
  active_account="$(active_gcloud_account)"
  if [ -z "$active_account" ]; then
    say "No active gcloud account found. Run: gcloud auth login"
    exit 1
  fi

  ensure_active_gcloud_project

  if ! gcloud projects describe "$GCLOUD_PROJECT_ID" >/dev/null 2>&1; then
    say "Unable to access project: ${GCLOUD_PROJECT_ID}"
    say "Make sure the project exists and your account has admin access."
    exit 1
  fi

  if [ ! -f "$repo_root/$BUILD_CONFIG_PATH" ]; then
    say "Build config file not found: $BUILD_CONFIG_PATH"
    exit 1
  fi

  say "Preflight checks passed for project ${GCLOUD_PROJECT_ID} using account ${active_account}"
}

ensure_apis() {
  say "Ensuring required Google APIs are enabled..."
  gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    secretmanager.googleapis.com \
    serviceusage.googleapis.com \
    --project="$GCLOUD_PROJECT_ID" >/dev/null
}

ensure_artifact_repo() {
  if gcloud artifacts repositories describe "$TARGET_ARTIFACT_REPO_APP" \
    --project="$GCLOUD_PROJECT_ID" \
    --location="$GCLOUD_REGION" >/dev/null 2>&1; then
    say "Artifact Registry repo exists: $TARGET_ARTIFACT_REPO_APP"
    return 0
  fi

  say "Creating Artifact Registry repo: $TARGET_ARTIFACT_REPO_APP"
  gcloud artifacts repositories create "$TARGET_ARTIFACT_REPO_APP" \
    --project="$GCLOUD_PROJECT_ID" \
    --location="$GCLOUD_REGION" \
    --repository-format=docker \
    --description="Application images for ${TARGET_SERVICE_NAME}." >/dev/null
}

ensure_service_account() {
  local sa_email
  sa_email="$(deploy_sa_email)"

  if gcloud iam service-accounts describe "$sa_email" \
    --project="$GCLOUD_PROJECT_ID" >/dev/null 2>&1; then
    say "Deployment service account exists: $sa_email"
  else
    say "Creating deployment service account: $sa_email"
    gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
      --project="$GCLOUD_PROJECT_ID" \
      --display-name="${GCLOUD_SERVICE_NAME} deploy"
    say "Waiting for service account to propagate..."
    sleep 15
  fi

  local service_agent
  service_agent="$(cloud_build_service_agent_email)"
  say "Allowing Cloud Build service agent to use $sa_email"
  gcloud iam service-accounts add-iam-policy-binding "$sa_email" \
    --project="$GCLOUD_PROJECT_ID" \
    --member="serviceAccount:${service_agent}" \
    --role="roles/iam.serviceAccountUser" >/dev/null
  gcloud iam service-accounts add-iam-policy-binding "$sa_email" \
    --project="$GCLOUD_PROJECT_ID" \
    --member="serviceAccount:${service_agent}" \
    --role="roles/iam.serviceAccountTokenCreator" >/dev/null
  gcloud iam service-accounts add-iam-policy-binding "$sa_email" \
    --project="$GCLOUD_PROJECT_ID" \
    --member="serviceAccount:${sa_email}" \
    --role="roles/iam.serviceAccountUser" >/dev/null
}

ensure_runtime_service_account_access() {
  local deploy_sa
  deploy_sa="$(deploy_sa_email)"

  if [ -z "$RUNTIME_SERVICE_ACCOUNT_EMAIL" ]; then
    say "RUNTIME_SERVICE_ACCOUNT_EMAIL is empty."
    exit 1
  fi

  if ! gcloud iam service-accounts describe "$RUNTIME_SERVICE_ACCOUNT_EMAIL" \
    --project="$GCLOUD_PROJECT_ID" >/dev/null 2>&1; then
    say "Runtime service account does not exist: ${RUNTIME_SERVICE_ACCOUNT_EMAIL}"
    say "Create it first, or leave RUNTIME_SERVICE_ACCOUNT_EMAIL unset to use the deploy service account."
    exit 1
  fi

  if [ "$RUNTIME_SERVICE_ACCOUNT_EMAIL" = "$deploy_sa" ]; then
    return 0
  fi

  say "Allowing deploy service account to use runtime service account: ${RUNTIME_SERVICE_ACCOUNT_EMAIL}"
  gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SERVICE_ACCOUNT_EMAIL" \
    --project="$GCLOUD_PROJECT_ID" \
    --member="serviceAccount:${deploy_sa}" \
    --role="roles/iam.serviceAccountUser" >/dev/null
}

ensure_project_iam() {
  local sa_email
  sa_email="$(deploy_sa_email)"

  say "Ensuring IAM roles for deployment service account: $sa_email"
  for role in \
    roles/artifactregistry.writer \
    roles/datastore.user \
    roles/logging.logWriter \
    roles/run.admin
  do
    gcloud projects add-iam-policy-binding "$GCLOUD_PROJECT_ID" \
      --member="serviceAccount:${sa_email}" \
      --role="$role" >/dev/null
  done
}

ensure_cloud_build_service_agent_project_iam() {
  local service_agent
  service_agent="$(cloud_build_service_agent_email)"

  say "Ensuring IAM roles for Cloud Build service agent: $service_agent"
  gcloud projects add-iam-policy-binding "$GCLOUD_PROJECT_ID" \
    --member="serviceAccount:${service_agent}" \
    --role="roles/secretmanager.admin" >/dev/null
}

ensure_connection() {
  if gcloud builds connections describe "$CONNECTION_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" >/dev/null 2>&1; then
    say "Cloud Build connection exists: ${connection_resource}"
    return 0
  fi

  say "Creating Cloud Build GitHub connection: ${connection_resource}"
  gcloud builds connections create github "$CONNECTION_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION"

  say
  say "If prompted, complete the one-time browser GitHub authorization."
}

connection_complete() {
  local stage
  stage="$(gcloud builds connections describe "$CONNECTION_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --format='value(installationState.stage)' 2>/dev/null || true)"
  [ "$stage" = "COMPLETE" ]
}

connection_exists() {
  gcloud builds connections describe "$CONNECTION_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" >/dev/null 2>&1
}

repository_exists() {
  gcloud builds repositories describe "$REPOSITORY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --connection="$CONNECTION_NAME" >/dev/null 2>&1
}

artifact_repo_exists() {
  gcloud artifacts repositories describe "$TARGET_ARTIFACT_REPO_APP" \
    --project="$GCLOUD_PROJECT_ID" \
    --location="$GCLOUD_REGION" >/dev/null 2>&1
}

service_account_exists() {
  gcloud iam service-accounts describe "$(deploy_sa_email)" \
    --project="$GCLOUD_PROJECT_ID" >/dev/null 2>&1
}

cloud_run_service_exists() {
  gcloud run services describe "$TARGET_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --platform=managed >/dev/null 2>&1
}

cloud_run_service_url() {
  gcloud run services describe "$TARGET_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --platform=managed \
    --format='value(status.url)'
}

domain_mapping_exists() {
  gcloud beta run domain-mappings list \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --format='value(metadata.name)' 2>/dev/null \
    | grep -Fx "$TARGET_SERVICE_DNS_NAME" >/dev/null 2>&1
}

ensure_domain_mapping() {
  if domain_mapping_exists; then
    say "Domain mapping exists: ${TARGET_SERVICE_DNS_NAME} -> ${TARGET_SERVICE_NAME}"
    return 0
  fi

  say "Creating domain mapping: ${TARGET_SERVICE_DNS_NAME} -> ${TARGET_SERVICE_NAME}"
  local output
  if ! output="$(gcloud beta run domain-mappings create \
    --service="$TARGET_SERVICE_NAME" \
    --domain="$TARGET_SERVICE_DNS_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" 2>&1)"; then
    if printf '%s' "$output" | grep -qi 'already exists'; then
      say "Domain mapping already exists: ${TARGET_SERVICE_DNS_NAME}"
      return 0
    fi
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

print_domain_mapping_dns() {
  if ! domain_mapping_exists; then
    say "No domain mapping found for: ${TARGET_SERVICE_DNS_NAME}"
    return 0
  fi

  say
  say "DNS records for ${TARGET_SERVICE_DNS_NAME} (set these in Porkbun):"
  gcloud beta run domain-mappings list \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --format='table(resourceRecords.type,resourceRecords.rrdata)' \
    --filter="metadata.name=${TARGET_SERVICE_DNS_NAME}"
}

delete_domain_mapping_if_exists() {
  if ! domain_mapping_exists; then
    say "Domain mapping already absent: ${TARGET_SERVICE_DNS_NAME}"
    return 0
  fi

  say "Deleting domain mapping: ${TARGET_SERVICE_DNS_NAME}"
  gcloud beta run domain-mappings delete "$TARGET_SERVICE_DNS_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --quiet
}

last_build_state_file() {
  printf '%s/last-build-%s' "$state_dir" "$ENVIRONMENT"
}

ensure_state_dir() {
  mkdir -p "$state_dir"
}

save_last_build_id() {
  local build_id="$1"
  if [ -z "$build_id" ]; then
    return 0
  fi
  ensure_state_dir
  printf '%s\n' "$build_id" > "$(last_build_state_file)"
}

load_last_build_id() {
  local state_file
  state_file="$(last_build_state_file)"
  if [ ! -f "$state_file" ]; then
    return 1
  fi
  cat "$state_file"
}

ensure_repository() {
  if gcloud builds repositories describe "$REPOSITORY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --connection="$CONNECTION_NAME" >/dev/null 2>&1; then
    say "Cloud Build repository exists: ${repository_resource}"
    return 0
  fi

  say "Creating Cloud Build repository mapping: ${repository_resource}"
  gcloud builds repositories create "$REPOSITORY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --connection="$CONNECTION_NAME" \
    --remote-uri="$GITHUB_REPO_URI"
}

trigger_exists() {
  local trigger_name="$1"
  gcloud builds triggers list \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --format='value(name)' | grep -Fx "$trigger_name" >/dev/null 2>&1
}

delete_trigger_if_exists() {
  local trigger_name="$1"
  if ! trigger_exists "$trigger_name"; then
    say "Cloud Build trigger already absent: $trigger_name"
    return 0
  fi

  say "Deleting Cloud Build trigger: $trigger_name"
  gcloud builds triggers delete "$trigger_name" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --quiet >/dev/null
}

ensure_auto_trigger() {
  local branch_pattern
  branch_pattern="^${DEPLOY_BRANCH}$"

  if trigger_exists "$TARGET_AUTO_TRIGGER_NAME"; then
    if [ "$RECREATE_CLOUD_BUILD_TRIGGERS" = "true" ]; then
      say "Recreating automatic trigger: $TARGET_AUTO_TRIGGER_NAME"
      gcloud builds triggers delete "$TARGET_AUTO_TRIGGER_NAME" \
        --project="$GCLOUD_PROJECT_ID" \
        --region="$GCLOUD_REGION" \
        --quiet >/dev/null
    else
      say "Automatic trigger exists: $TARGET_AUTO_TRIGGER_NAME"
      return 0
    fi
  fi

  say "Creating automatic trigger: $TARGET_AUTO_TRIGGER_NAME"
  gcloud builds triggers create github \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --name="$TARGET_AUTO_TRIGGER_NAME" \
    --repository="$repository_resource" \
    --branch-pattern="$branch_pattern" \
    --build-config="$BUILD_CONFIG_PATH" \
    --included-files="$INCLUDED_FILES" \
    --service-account="$(deploy_sa_resource)" \
    --substitutions="$(trigger_substitutions)" \
    --description="Build and deploy ${TARGET_SERVICE_NAME} to Cloud Run on pushes to ${DEPLOY_BRANCH}."
}

ensure_manual_trigger() {
  if trigger_exists "$TARGET_MANUAL_TRIGGER_NAME"; then
    if [ "$RECREATE_CLOUD_BUILD_TRIGGERS" = "true" ]; then
      say "Recreating manual trigger: $TARGET_MANUAL_TRIGGER_NAME"
      gcloud builds triggers delete "$TARGET_MANUAL_TRIGGER_NAME" \
        --project="$GCLOUD_PROJECT_ID" \
        --region="$GCLOUD_REGION" \
        --quiet >/dev/null
    else
      say "Manual trigger exists: $TARGET_MANUAL_TRIGGER_NAME"
      return 0
    fi
  fi

  say "Creating manual trigger: $TARGET_MANUAL_TRIGGER_NAME"
  gcloud builds triggers create manual \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --name="$TARGET_MANUAL_TRIGGER_NAME" \
    --repository="$repository_resource" \
    --branch="$DEPLOY_BRANCH" \
    --build-config="$BUILD_CONFIG_PATH" \
    --service-account="$(deploy_sa_resource)" \
    --substitutions="$(trigger_substitutions)" \
    --description="Manual build and deploy of ${TARGET_SERVICE_NAME} to Cloud Run from ${DEPLOY_BRANCH}."
}

run_manual_trigger() {
  say "Running Cloud Build manual trigger: ${TARGET_MANUAL_TRIGGER_NAME}" >&2
  gcloud builds triggers run "$TARGET_MANUAL_TRIGGER_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --branch="$DEPLOY_BRANCH" \
    --format='value(metadata.build.id)'
}

wait_for_build() {
  local build_id="$1"
  local status=""

  if [ -z "$build_id" ]; then
    say "Failed to determine Cloud Build id."
    exit 1
  fi

  say "Waiting for Cloud Build: ${build_id}"
  while true; do
    status="$(gcloud builds describe "$build_id" \
      --project="$GCLOUD_PROJECT_ID" \
      --region="$GCLOUD_REGION" \
      --format='value(status)')"
    case "$status" in
      SUCCESS)
        say "Cloud Build succeeded: ${build_id}"
        return 0
        ;;
      FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED|EXPIRED)
        say "Cloud Build failed with status ${status}: ${build_id}"
        exit 1
        ;;
      *)
        sleep 10
        ;;
    esac
  done
}

require_created_artifacts() {
  local missing=()

  connection_exists || missing+=("connection")
  repository_exists || missing+=("repository-mapping")
  service_account_exists || missing+=("service-account")
  artifact_repo_exists || missing+=("artifact-registry")

  if [ "$ENVIRONMENT" = "prod" ]; then
    trigger_exists "$TARGET_AUTO_TRIGGER_NAME" || missing+=("prod-auto-trigger")
    trigger_exists "$TARGET_MANUAL_TRIGGER_NAME" || missing+=("prod-manual-trigger")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    say "Missing required artifacts for ${ENVIRONMENT} deploy: $(IFS=', '; printf '%s' "${missing[*]}")"
    if [ "$ENVIRONMENT" = "test" ]; then
      say "Run: bash cicd/setupsvc.sh create --test"
    else
      say "Run: bash cicd/setupsvc.sh create"
    fi
    exit 1
  fi
}

run_create() {
  configure_environment

  require_cmd gcloud
  preflight_create

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"
  say "Domain: ${TARGET_SERVICE_DNS_NAME}"

  ensure_apis
  ensure_cloud_build_service_agent_project_iam
  ensure_service_account
  ensure_runtime_service_account_access
  ensure_project_iam
  require_github_repo_uri
  ensure_connection
  if ! connection_complete; then
    say
    say "Cloud Build GitHub connection is not yet complete."
    say "Finish the GitHub authorization and re-run this script."
    exit 1
  fi
  ensure_repository
  ensure_artifact_repo

  if [ "$ENVIRONMENT" = "prod" ]; then
    ensure_auto_trigger
    ensure_manual_trigger
  fi

  say
  say "Artifact creation complete."
  say "Environment: ${ENVIRONMENT}"
  if [ "$ENVIRONMENT" = "prod" ]; then
    say "Cloud Build auto trigger: ${TARGET_AUTO_TRIGGER_NAME}"
    say "Cloud Build manual trigger: ${TARGET_MANUAL_TRIGGER_NAME}"
  else
    say "Test triggers are created on demand by deploy --test --branch <name>."
  fi
}

run_deploy() {
  local build_id=""

  configure_environment

  require_cmd gcloud

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"
  say "Domain: ${TARGET_SERVICE_DNS_NAME}"

  require_created_artifacts

  if [ "$ENVIRONMENT" = "test" ]; then
    require_github_repo_uri
    ensure_auto_trigger
    ensure_manual_trigger
  fi

  if ! trigger_exists "$TARGET_MANUAL_TRIGGER_NAME"; then
    say "Manual trigger does not exist: ${TARGET_MANUAL_TRIGGER_NAME}"
    if [ "$ENVIRONMENT" = "prod" ]; then
      say "Run: bash cicd/setupsvc.sh create"
    else
      say "Re-run deploy with --test --branch <name> after create completes."
    fi
    exit 1
  fi

  build_id="$(run_manual_trigger)"
  save_last_build_id "$build_id"
  wait_for_build "$build_id"

  if cloud_run_service_exists; then
    ensure_domain_mapping
    print_domain_mapping_dns
  fi

  say
  say "Deployment complete."
  say "Environment: ${ENVIRONMENT}"
  say "Build id: ${build_id}"
}

run_status() {
  configure_environment

  require_cmd gcloud
  require_cmd curl

  local service_url=""
  local service_health="missing"
  local http_code=""
  local trigger_summary="missing"
  local domain_status="missing"

  if cloud_run_service_exists; then
    service_url="$(cloud_run_service_url)"
    if http_code="$(curl -fsS -o /dev/null -w '%{http_code}' "${service_url}/" 2>/dev/null)"; then
      if [ "$http_code" = "200" ]; then
        service_health="healthy"
      else
        service_health="http-${http_code}"
      fi
    else
      service_health="unreachable"
    fi
  fi

  if [ "$ENVIRONMENT" = "prod" ]; then
    if trigger_exists "$TARGET_AUTO_TRIGGER_NAME" && trigger_exists "$TARGET_MANUAL_TRIGGER_NAME"; then
      trigger_summary="present"
    else
      trigger_summary="missing"
    fi
  else
    if trigger_exists "$TARGET_AUTO_TRIGGER_NAME" || trigger_exists "$TARGET_MANUAL_TRIGGER_NAME"; then
      trigger_summary="present"
    else
      trigger_summary="not-created-yet"
    fi
  fi

  if domain_mapping_exists; then
    domain_status="present"
  else
    domain_status="missing"
  fi

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"
  say "Domain: ${TARGET_SERVICE_DNS_NAME}"
  say
  say "Artifacts:"
  say "  Connection: $(connection_exists && printf present || printf missing)"
  say "  Repository mapping: $(repository_exists && printf present || printf missing)"
  say "  Service account: $(service_account_exists && printf present || printf missing)"
  say "  Artifact Registry: $(artifact_repo_exists && printf present || printf missing)"
  say "  Trigger(s): ${trigger_summary}"
  say
  say "Service:"
  say "  Cloud Run: $(cloud_run_service_exists && printf present || printf missing)"
  say "  URL: ${service_url:-n/a}"
  say "  Health: ${service_health}"
  say
  say "Domain mapping: ${domain_status}"
}

run_chkdomain() {
  configure_environment

  require_cmd gcloud

  say "Environment: ${ENVIRONMENT}"
  say "Domain: ${TARGET_SERVICE_DNS_NAME}"

  if ! domain_mapping_exists; then
    say "No domain mapping found."
    say "Deploy first: bash cicd/setupsvc.sh deploy"
    return 0
  fi

  gcloud beta run domain-mappings list \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --filter="metadata.name=${TARGET_SERVICE_DNS_NAME}" \
    --format='yaml(metadata.name,status.conditions,status.mappedRouteName)'

  print_domain_mapping_dns
}

resolve_build_id() {
  local build_id="$EXPLICIT_BUILD_ID"

  if [ -z "$build_id" ]; then
    build_id="$(load_last_build_id 2>/dev/null || true)"
  fi

  if [ -z "$build_id" ]; then
    say "No saved build id for environment: ${ENVIRONMENT}"
    say "Run deploy first, or pass --build-id <id>."
    exit 1
  fi

  printf '%s\n' "$build_id"
}

run_chkbuild() {
  configure_environment

  require_cmd gcloud

  local build_id=""
  build_id="$(resolve_build_id)"

  say "Environment: ${ENVIRONMENT}"
  say "Build id: ${build_id}"

  gcloud builds log "$build_id" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION"
}

run_tailbuild() {
  require_cmd gcloud

  say "Project: ${GCLOUD_PROJECT_ID}"
  say "Region: ${GCLOUD_REGION}"
  say "Build id: ${TAIL_BUILD_ID}"
  say "Streaming Cloud Build log..."

  gcloud beta builds log "$TAIL_BUILD_ID" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --stream
}

run_lsbuild() {
  require_cmd gcloud

  say "Project: ${GCLOUD_PROJECT_ID}"
  say "Region: ${GCLOUD_REGION}"

  gcloud builds list \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --limit=10 \
    --sort-by='~createTime'
}

run_logsvc() {
  configure_environment

  require_cmd gcloud

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"
  say "Streaming Cloud Run service logs..."

  gcloud beta run services logs tail "$TARGET_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION"
}

run_chksvc() {
  configure_environment

  require_cmd gcloud
  require_cmd curl

  local service_url
  local http_code

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"

  if ! cloud_run_service_exists; then
    say "Cloud Run service does not exist: ${TARGET_SERVICE_NAME}"
    exit 1
  fi

  service_url="$(cloud_run_service_url)"
  say "Service URL: ${service_url}"

  http_code="$(curl -fsS -o /dev/null -w '%{http_code}' "${service_url}/")"

  if [ "$http_code" != "200" ]; then
    say "Health check failed: expected HTTP 200, got ${http_code}"
    exit 1
  fi

  say "Service health check passed."
  say "HTTP status: ${http_code}"
}

run_delete() {
  configure_environment

  require_cmd gcloud

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"
  say "Domain: ${TARGET_SERVICE_DNS_NAME}"

  delete_trigger_if_exists "$TARGET_MANUAL_TRIGGER_NAME"
  delete_trigger_if_exists "$TARGET_AUTO_TRIGGER_NAME"
  delete_domain_mapping_if_exists

  if cloud_run_service_exists; then
    say "Deleting Cloud Run service: $TARGET_SERVICE_NAME"
    gcloud run services delete "$TARGET_SERVICE_NAME" \
      --project="$GCLOUD_PROJECT_ID" \
      --region="$GCLOUD_REGION" \
      --platform=managed \
      --quiet >/dev/null
  else
    say "Cloud Run service already absent: $TARGET_SERVICE_NAME"
  fi

  if gcloud artifacts repositories describe "$TARGET_ARTIFACT_REPO_APP" \
    --project="$GCLOUD_PROJECT_ID" \
    --location="$GCLOUD_REGION" >/dev/null 2>&1; then
    say "Deleting Artifact Registry repo: $TARGET_ARTIFACT_REPO_APP"
    gcloud artifacts repositories delete "$TARGET_ARTIFACT_REPO_APP" \
      --project="$GCLOUD_PROJECT_ID" \
      --location="$GCLOUD_REGION" \
      --quiet >/dev/null
  else
    say "Artifact Registry repo already absent: $TARGET_ARTIFACT_REPO_APP"
  fi

  say
  say "Delete complete."
  say "Environment: ${ENVIRONMENT}"
  say "Shared resources left in place: ${CONNECTION_NAME}, ${REPOSITORY_NAME}, ${SERVICE_ACCOUNT_NAME}"
}

main() {
  parse_args "$@"

  case "$COMMAND" in
    create)   run_create   ;;
    deploy)   run_deploy   ;;
    delete)   run_delete   ;;
    status)   run_status   ;;
    chkdomain) run_chkdomain ;;
    chkbuild) run_chkbuild ;;
    tailbuild) run_tailbuild ;;
    lsbuild)  run_lsbuild  ;;
    logsvc)   run_logsvc   ;;
    chksvc)   run_chksvc   ;;
    *)
      say "Unsupported command: ${COMMAND}"
      exit 1
      ;;
  esac
}

main "$@"
