#!/usr/bin/env bash

set -euo pipefail

GCLOUD_PROJECT_ID="${GCLOUD_PROJECT_ID:-xlentors-dev}"
GCLOUD_REGION="${GCLOUD_REGION:-us-central1}"

WEBSITE_HOSTNAME="${WEBSITE_HOSTNAME:-xlentors.dev}"

GCLOUD_SERVICE_NAME="${GCLOUD_SERVICE_NAME:-xlentors-dev}"
BASE_SERVICE_DNS_NAME="${BASE_SERVICE_DNS_NAME:-$WEBSITE_HOSTNAME}"
BASE_GLOBAL_IP_NAME="${BASE_GLOBAL_IP_NAME:-${GCLOUD_SERVICE_NAME}-ingress-ip}"

TEST_ENV_PREFIX="${TEST_ENV_PREFIX:-test-}"
TEST_SERVICE_DNS_NAME="${TEST_SERVICE_DNS_NAME:-${TEST_ENV_PREFIX}${WEBSITE_HOSTNAME}}"

ENVIRONMENT="${ENVIRONMENT:-prod}"
TARGET_SERVICE_NAME="${TARGET_SERVICE_NAME:-}"
TARGET_SERVICE_DNS_NAME="${TARGET_SERVICE_DNS_NAME:-}"
TARGET_GLOBAL_IP_NAME="${TARGET_GLOBAL_IP_NAME:-}"

SERVERLESS_NEG_NAME=""
BACKEND_SERVICE_NAME=""
URL_MAP_NAME=""
HTTP_REDIRECT_MAP_NAME=""
HTTPS_PROXY_NAME=""
HTTP_PROXY_NAME=""
SSL_CERT_NAME=""
ACTIVE_SSL_CERT_NAME=""
HTTPS_FORWARDING_RULE_NAME=""
HTTP_FORWARDING_RULE_NAME=""

say() {
  printf '%s\n' "$*"
}

retry_transient_gcloud() {
  local description="$1"
  shift

  local attempt=1
  local max_attempts=6
  local sleep_seconds=10
  local output=""

  while true; do
    if output="$("$@" 2>&1)"; then
      [ -n "$output" ] && printf '%s\n' "$output"
      return 0
    fi

    if [ "$attempt" -ge "$max_attempts" ]; then
      [ -n "$output" ] && printf '%s\n' "$output" >&2
      return 1
    fi

    if printf '%s' "$output" | grep -Eiq 'is not ready|resource.*not ready|resourceNotReady'; then
      say "${description} not ready yet. Retrying in ${sleep_seconds}s (attempt ${attempt}/${max_attempts})..."
      sleep "$sleep_seconds"
      attempt=$((attempt + 1))
      continue
    fi

    [ -n "$output" ] && printf '%s\n' "$output" >&2
    return 1
  done
}

usage() {
  cat <<'EOF'
Usage:
  bash cicd/reconcile-service-ingress.sh [--test]

Options:
  --test        Reconcile the test environment instead of production.
  --env <name>  Explicitly set the environment name.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --test)
        ENVIRONMENT="test"
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
    TARGET_GLOBAL_IP_NAME="${TARGET_GLOBAL_IP_NAME:-${TEST_ENV_PREFIX}${BASE_GLOBAL_IP_NAME}}"
  else
    TARGET_SERVICE_NAME="${TARGET_SERVICE_NAME:-$GCLOUD_SERVICE_NAME}"
    TARGET_SERVICE_DNS_NAME="${TARGET_SERVICE_DNS_NAME:-$BASE_SERVICE_DNS_NAME}"
    TARGET_GLOBAL_IP_NAME="${TARGET_GLOBAL_IP_NAME:-$BASE_GLOBAL_IP_NAME}"
  fi

  SERVERLESS_NEG_NAME="${TARGET_SERVICE_NAME}-neg"
  BACKEND_SERVICE_NAME="${TARGET_SERVICE_NAME}-backend"
  URL_MAP_NAME="${TARGET_SERVICE_NAME}-url-map"
  HTTP_REDIRECT_MAP_NAME="${TARGET_SERVICE_NAME}-http-redirect"
  HTTPS_PROXY_NAME="${TARGET_SERVICE_NAME}-https-proxy"
  HTTP_PROXY_NAME="${TARGET_SERVICE_NAME}-http-proxy"
  SSL_CERT_NAME="${TARGET_SERVICE_NAME}-managed-cert"
  HTTPS_FORWARDING_RULE_NAME="${TARGET_SERVICE_NAME}-https-fr"
  HTTP_FORWARDING_RULE_NAME="${TARGET_SERVICE_NAME}-http-fr"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    say "Missing required command: $1"
    exit 1
  fi
}

cloud_run_service_exists() {
  gcloud run services describe "$TARGET_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --platform=managed >/dev/null 2>&1
}

ensure_ssl_certificate() {
  if gcloud compute ssl-certificates describe "$SSL_CERT_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "Managed SSL certificate exists: $SSL_CERT_NAME"
    return 0
  fi

  say "Creating managed SSL certificate: $SSL_CERT_NAME"
  gcloud compute ssl-certificates create "$SSL_CERT_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --domains="$TARGET_SERVICE_DNS_NAME" >/dev/null
}

select_active_ssl_certificate() {
  printf '%s\n' "$SSL_CERT_NAME"
}

print_ssl_status() {
  say "SSL certificate status:"
  gcloud compute ssl-certificates describe "$SSL_CERT_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --format='yaml(name,managed.status,managed.domainStatus)'
}

ensure_serverless_neg() {
  if gcloud compute network-endpoint-groups describe "$SERVERLESS_NEG_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" >/dev/null 2>&1; then
    say "Serverless NEG exists: $SERVERLESS_NEG_NAME"
    return 0
  fi

  say "Creating serverless NEG: $SERVERLESS_NEG_NAME"
  gcloud compute network-endpoint-groups create "$SERVERLESS_NEG_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --region="$GCLOUD_REGION" \
    --network-endpoint-type=serverless \
    --cloud-run-service="$TARGET_SERVICE_NAME" >/dev/null
}

ensure_backend_service() {
  if gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "Backend service exists: $BACKEND_SERVICE_NAME"
  else
    say "Creating backend service: $BACKEND_SERVICE_NAME"
    gcloud compute backend-services create "$BACKEND_SERVICE_NAME" \
      --project="$GCLOUD_PROJECT_ID" \
      --global \
      --load-balancing-scheme=EXTERNAL_MANAGED >/dev/null
  fi

  local backend_group
  backend_group="$(gcloud compute backend-services describe "$BACKEND_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --format='value(backends[0].group)' 2>/dev/null || true)"

  if printf '%s' "$backend_group" | grep -F "${SERVERLESS_NEG_NAME}" >/dev/null 2>&1; then
    say "Backend already attached to backend service: $SERVERLESS_NEG_NAME"
    return 0
  fi

  say "Attaching serverless NEG to backend service: $SERVERLESS_NEG_NAME"
  retry_transient_gcloud "Backend service attachment" \
    gcloud compute backend-services add-backend "$BACKEND_SERVICE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --network-endpoint-group="$SERVERLESS_NEG_NAME" \
    --network-endpoint-group-region="$GCLOUD_REGION" >/dev/null
}

ensure_url_map() {
  if gcloud compute url-maps describe "$URL_MAP_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "URL map exists: $URL_MAP_NAME"
    retry_transient_gcloud "URL map update" \
      gcloud compute url-maps set-default-service "$URL_MAP_NAME" \
      --project="$GCLOUD_PROJECT_ID" \
      --global \
      --default-service="$BACKEND_SERVICE_NAME" >/dev/null
    return 0
  fi

  say "Creating URL map: $URL_MAP_NAME"
  retry_transient_gcloud "URL map creation" \
    gcloud compute url-maps create "$URL_MAP_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --default-service="$BACKEND_SERVICE_NAME" >/dev/null
}

ensure_http_redirect_url_map() {
  local tmp_file
  tmp_file="$(mktemp)"
  cat > "$tmp_file" <<EOF
name: ${HTTP_REDIRECT_MAP_NAME}
defaultUrlRedirect:
  httpsRedirect: true
  redirectResponseCode: MOVED_PERMANENTLY_DEFAULT
EOF

  say "Importing HTTP redirect URL map: $HTTP_REDIRECT_MAP_NAME"
  retry_transient_gcloud "HTTP redirect URL map import" \
    gcloud compute url-maps import "$HTTP_REDIRECT_MAP_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --source="$tmp_file" \
    --quiet >/dev/null
  rm -f "$tmp_file"
}

ensure_https_proxy() {
  ACTIVE_SSL_CERT_NAME="$(select_active_ssl_certificate)"
  if gcloud compute target-https-proxies describe "$HTTPS_PROXY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "HTTPS proxy exists: $HTTPS_PROXY_NAME"
    retry_transient_gcloud "HTTPS proxy update" \
      gcloud compute target-https-proxies update "$HTTPS_PROXY_NAME" \
      --project="$GCLOUD_PROJECT_ID" \
      --global \
      --url-map="$URL_MAP_NAME" \
      --ssl-certificates="$ACTIVE_SSL_CERT_NAME" >/dev/null
    return 0
  fi

  say "Creating HTTPS proxy: $HTTPS_PROXY_NAME"
  retry_transient_gcloud "HTTPS proxy creation" \
    gcloud compute target-https-proxies create "$HTTPS_PROXY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --url-map="$URL_MAP_NAME" \
    --ssl-certificates="$ACTIVE_SSL_CERT_NAME" >/dev/null
}

ensure_http_proxy() {
  if gcloud compute target-http-proxies describe "$HTTP_PROXY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "HTTP proxy exists: $HTTP_PROXY_NAME"
    retry_transient_gcloud "HTTP proxy update" \
      gcloud compute target-http-proxies update "$HTTP_PROXY_NAME" \
      --project="$GCLOUD_PROJECT_ID" \
      --global \
      --url-map="$HTTP_REDIRECT_MAP_NAME" >/dev/null
    return 0
  fi

  say "Creating HTTP proxy: $HTTP_PROXY_NAME"
  retry_transient_gcloud "HTTP proxy creation" \
    gcloud compute target-http-proxies create "$HTTP_PROXY_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --url-map="$HTTP_REDIRECT_MAP_NAME" >/dev/null
}

ensure_https_forwarding_rule() {
  if gcloud compute forwarding-rules describe "$HTTPS_FORWARDING_RULE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "HTTPS forwarding rule exists: $HTTPS_FORWARDING_RULE_NAME"
    return 0
  fi

  say "Creating HTTPS forwarding rule: $HTTPS_FORWARDING_RULE_NAME"
  retry_transient_gcloud "HTTPS forwarding rule creation" \
    gcloud compute forwarding-rules create "$HTTPS_FORWARDING_RULE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --target-https-proxy="$HTTPS_PROXY_NAME" \
    --ports=443 \
    --address="$TARGET_GLOBAL_IP_NAME" >/dev/null
}

ensure_http_forwarding_rule() {
  if gcloud compute forwarding-rules describe "$HTTP_FORWARDING_RULE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "HTTP forwarding rule exists: $HTTP_FORWARDING_RULE_NAME"
    return 0
  fi

  say "Creating HTTP forwarding rule: $HTTP_FORWARDING_RULE_NAME"
  retry_transient_gcloud "HTTP forwarding rule creation" \
    gcloud compute forwarding-rules create "$HTTP_FORWARDING_RULE_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global \
    --target-http-proxy="$HTTP_PROXY_NAME" \
    --ports=80 \
    --address="$TARGET_GLOBAL_IP_NAME" >/dev/null
}

main() {
  parse_args "$@"
  configure_environment

  require_cmd gcloud

  say "Environment: ${ENVIRONMENT}"
  say "Cloud Run service: ${TARGET_SERVICE_NAME}"
  say "DNS: ${TARGET_SERVICE_DNS_NAME}"

  if ! cloud_run_service_exists; then
    say "Cloud Run service does not exist yet: ${TARGET_SERVICE_NAME}"
    exit 1
  fi

  if ! gcloud compute addresses describe "$TARGET_GLOBAL_IP_NAME" \
    --project="$GCLOUD_PROJECT_ID" \
    --global >/dev/null 2>&1; then
    say "No static IP found. Skipping load balancer reconciliation (using Cloud Run domain mapping)."
    exit 0
  fi

  ensure_ssl_certificate
  ensure_serverless_neg
  ensure_backend_service
  ensure_url_map
  ensure_http_redirect_url_map
  ensure_https_proxy
  ensure_http_proxy
  ensure_https_forwarding_rule
  ensure_http_forwarding_rule
  print_ssl_status
  say "HTTPS proxy certificate: ${ACTIVE_SSL_CERT_NAME}"
}

main "$@"
