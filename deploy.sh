#!/bin/bash
set -euo pipefail

# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN
# DEBIAN BOOKWORM
#
# ARCHITECTURE
#
# Cloud Run :8080
#       |
#       v
#     Envoy
#     /   \
#    /     \
#  Xray   Apache
#
# INTERNAL ONLY:
#   HAProxy   :8081 / :8086
#   OpenResty :8084
#   Apache    :8083
#   Xray      :10000-10015
#
# IMPORTANT:
#   DEPLOY=false by default.
#   Set DEPLOY=true only when ready.
# ============================================================


# ============================================================
# CONFIG
# ============================================================

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"

REGION="${REGION:-asia-southeast1}"

SERVICE_NAME="${SERVICE_NAME:-virgozki}"

REPOSITORY="${REPOSITORY:-virgozki}"

IMAGE_NAME="${IMAGE_NAME:-virgozki}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

DEPLOY="${DEPLOY:-false}"


# ============================================================
# CLOUD RUN RESOURCES
# ============================================================

CPU="${CPU:-2}"
RAM="${RAM:-2Gi}"

MAX_INST="${MAX_INST:-10}"

CONCURRENCY="${CONCURRENCY:-80}"

TIMEOUT="${TIMEOUT:-3600}"


# ============================================================
# COLORS
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'


# ============================================================
# FUNCTIONS
# ============================================================

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

ok() {
    echo -e "${GREEN}[ OK ]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    exit 1
}


# ============================================================
# HEADER
# ============================================================

echo
echo "============================================================"
echo " VIRGOZKI 4-PROXY + gRPC | CLOUD RUN"
echo "============================================================"
echo
echo "Project      : ${PROJECT_ID}"
echo "Region       : ${REGION}"
echo "Service      : ${SERVICE_NAME}"
echo "Image        : ${IMAGE}"
echo "Deploy       : ${DEPLOY}"
echo
echo "Public port  : 8080"
echo "HAProxy HTTP : 8081"
echo "Apache       : 8083"
echo "OpenResty    : 8084"
echo "HAProxy gRPC : 8086"
echo "Xray         : 10000-10015"
echo


# ============================================================
# CHECK PROJECT
# ============================================================

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    fail "PROJECT_ID is not set."
fi

gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1 \
    || fail "Cannot access GCP project: ${PROJECT_ID}"

ok "GCP project accessible"


# ============================================================
# CHECK REQUIRED COMMANDS
# ============================================================

for cmd in gcloud curl python3; do
    command -v "${cmd}" >/dev/null 2>&1 \
        || fail "Required command not found: ${cmd}"
done

ok "Required local commands available"


# ============================================================
# REQUIRED FILES
# ============================================================

REQUIRED_FILES=(
    "Dockerfile"
    "supervisord.conf"
    "config.json"
    "nginx.conf"
    "haproxy.cfg"
    "envoy.yaml"
    "httpd.conf"
    "index.html"
    "anti_ddos.py"
)

info "Checking required files..."

for file in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${file}" ]]; then
        fail "Missing file: ${file}"
    fi

    ok "Found ${file}"
done


# ============================================================
# CHECK CONFIG.JSON SYNTAX
# ============================================================

info "Checking config.json syntax..."

python3 - <<'PY'
import json
import sys

try:
    with open("config.json", "r", encoding="utf-8") as f:
        json.load(f)

    print("[ OK ] config.json is valid JSON")

except Exception as e:
    print("[FAIL] config.json is invalid:")
    print(e)
    sys.exit(1)
PY


# ============================================================
# CHECK DOCKERFILE
# ============================================================

info "Checking Dockerfile..."

grep -q '^FROM envoyproxy/envoy:v1.39.1 AS envoy' Dockerfile \
    || fail "Envoy base stage missing"

grep -q '^FROM ghcr.io/xtls/xray-core:25.12.8 AS xray' Dockerfile \
    || fail "Xray base stage missing"

grep -q '^FROM openresty/openresty:1.31.1.1-bookworm-fat AS final' Dockerfile \
    || fail "OpenResty final stage missing"

grep -q 'COPY supervisord.conf /etc/supervisord.conf' Dockerfile \
    || fail "supervisord.conf COPY missing"

grep -q 'COPY config.json /etc/xray/config.json' Dockerfile \
    || fail "config.json COPY missing"

grep -q 'COPY nginx.conf /etc/openresty/nginx.conf' Dockerfile \
    || fail "nginx.conf COPY missing"

grep -q 'COPY haproxy.cfg /etc/haproxy/haproxy.cfg' Dockerfile \
    || fail "haproxy.cfg COPY missing"

grep -q 'COPY envoy.yaml /etc/envoy/envoy.yaml' Dockerfile \
    || fail "envoy.yaml COPY missing"

grep -q 'COPY httpd.conf /etc/apache2/conf-available/virgozki.conf' Dockerfile \
    || fail "httpd.conf COPY missing"

grep -q 'COPY anti_ddos.py /usr/local/bin/anti_ddos.py' Dockerfile \
    || fail "anti_ddos.py COPY missing"

ok "Dockerfile structure looks correct"


# ============================================================
# CHECK SUPERVISOR
# ============================================================

info "Checking Supervisor configuration..."

grep -q 'xray run -c /etc/xray/config.json' supervisord.conf \
    || fail "Supervisor Xray command missing"

grep -q 'apachectl -DFOREGROUND' supervisord.conf \
    || fail "Supervisor Apache command missing"

grep -q 'haproxy -W -db -f /etc/haproxy/haproxy.cfg' supervisord.conf \
    || fail "Supervisor HAProxy command missing"

grep -q 'openresty -c /etc/openresty/nginx.conf' supervisord.conf \
    || fail "Supervisor OpenResty config path missing"

grep -q 'envoy -c /etc/envoy/envoy.yaml' supervisord.conf \
    || fail "Supervisor Envoy command missing"

ok "Supervisor configuration looks correct"


# ============================================================
# CHECK PORT ALIGNMENT
# ============================================================

info "Checking port alignment..."

grep -q 'port_value: 8080' envoy.yaml \
    || fail "Envoy is not listening on port 8080"

grep -q 'Listen 127.0.0.1:8083' httpd.conf \
    || fail "Apache is not configured for 127.0.0.1:8083"

grep -q 'bind 127.0.0.1:8081' haproxy.cfg \
    || fail "HAProxy HTTP listener 8081 missing"

grep -q 'bind 127.0.0.1:8086' haproxy.cfg \
    || fail "HAProxy gRPC listener 8086 missing"

grep -q 'listen 127.0.0.1:8084' nginx.conf \
    || fail "OpenResty listener 8084 missing"

ok "Internal port alignment looks correct"


# ============================================================
# CHECK FOR OLD HAProxy 8084 COLLISION
# ============================================================

info "Checking old HAProxy/OpenResty port collision..."

if grep -Eq 'bind[[:space:]]+127\.0\.0\.1:8084' haproxy.cfg; then
    fail "HAProxy still uses 8084. This conflicts with OpenResty."
fi

ok "No HAProxy 8084 collision found"


# ============================================================
# CHECK GRPC PATHS
# ============================================================

info "Checking gRPC paths..."

GRPC_PATHS=(
    "vless-grpc-virgozki"
    "vmess-grpc-virgozki"
    "trojan-grpc-virgozki"
    "ss-grpc-virgozki"
)

for path in "${GRPC_PATHS[@]}"; do

    grep -q "${path}" envoy.yaml \
        || fail "Missing gRPC path in envoy.yaml: ${path}"

    grep -q "${path}" config.json \
        || fail "Missing gRPC serviceName in config.json: ${path}"

    grep -q "${path}" nginx.conf \
        || fail "Missing gRPC path in nginx.conf: ${path}"

    ok "gRPC path aligned: ${path}"

done


# ============================================================
# CHECK XRAY PORTS
# ============================================================

info "Checking Xray ports..."

for port in \
    10000 \
    10001 \
    10002 \
    10003 \
    10004 \
    10005 \
    10006 \
    10007 \
    10008 \
    10009 \
    10010 \
    10011 \
    10012 \
    10013 \
    10014 \
    10015
do

    grep -q "\"port\": ${port}" config.json \
        || fail "Xray port missing from config.json: ${port}"

    grep -q "port_value: ${port}" envoy.yaml \
        || fail "Xray port missing from envoy.yaml: ${port}"

done

ok "All Xray ports 10000-10015 are aligned"


# ============================================================
# CHECK HEALTH ROUTES
# ============================================================

info "Checking health endpoints..."

grep -q '/health' envoy.yaml \
    || fail "Envoy /health route missing"

grep -q '/health' nginx.conf \
    || fail "OpenResty /health route missing"

grep -q '/health' httpd.conf \
    || fail "Apache /health route missing"

ok "Health routes found"


# ============================================================
# CHECK PUBLIC LISTENER
# ============================================================

info "Checking public listener..."

grep -q 'port_value: 8080' envoy.yaml \
    || fail "Public Envoy listener 8080 not found"

ok "Envoy public listener is 8080"


# ============================================================
# ENABLE REQUIRED APIS
# ============================================================

info "Enabling required Google Cloud APIs..."

gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --project="${PROJECT_ID}"

ok "Required APIs enabled"


# ============================================================
# CREATE ARTIFACT REGISTRY
# ============================================================

info "Checking Artifact Registry repository..."

if ! gcloud artifacts repositories describe "${REPOSITORY}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" >/dev/null 2>&1
then

    info "Creating Artifact Registry repository..."

    gcloud artifacts repositories create "${REPOSITORY}" \
        --repository-format=docker \
        --location="${REGION}" \
        --description="VIRGOZKI Cloud Run images" \
        --project="${PROJECT_ID}"

    ok "Artifact Registry repository created"

else

    ok "Artifact Registry repository already exists"

fi


# ============================================================
# BUILD IMAGE
# ============================================================

echo
echo "============================================================"
echo " BUILDING CONTAINER IMAGE"
echo "============================================================"
echo

gcloud builds submit \
    --tag "${IMAGE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}"

ok "Container image built successfully"


# ============================================================
# DO NOT DEPLOY BY DEFAULT
# ============================================================

if [[ "${DEPLOY}" != "true" ]]; then

    echo
    echo "============================================================"
    echo " BUILD TEST COMPLETE"
    echo "============================================================"
    echo
    echo "Image:"
    echo "  ${IMAGE}"
    echo
    echo "Deployment was NOT performed."
    echo
    echo "To deploy later:"
    echo
    echo "  DEPLOY=true ./deploy.sh"
    echo
    echo "============================================================"
    exit 0
fi


# ============================================================
# CLOUD RUN DEPLOY
# ============================================================

echo
echo "============================================================"
echo " DEPLOYING TO CLOUD RUN"
echo "============================================================"
echo

gcloud run deploy "${SERVICE_NAME}" \
    --image="${IMAGE}" \
    --platform=managed \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --cpu="${CPU}" \
    --memory="${RAM}" \
    --port=8080 \
    --concurrency="${CONCURRENCY}" \
    --timeout="${TIMEOUT}" \
    --min-instances=0 \
    --max-instances="${MAX_INST}" \
    --session-affinity \
    --allow-unauthenticated \
    --quiet


# ============================================================
# GET SERVICE URL
# ============================================================

SERVICE_URL="$(
    gcloud run services describe "${SERVICE_NAME}" \
        --platform=managed \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --format='value(status.url)'
)"

if [[ -z "${SERVICE_URL}" ]]; then
    fail "Unable to obtain Cloud Run service URL"
fi

ok "Cloud Run URL: ${SERVICE_URL}"


# ============================================================
# WAIT FOR STARTUP
# ============================================================

info "Waiting for Cloud Run startup..."

sleep 8


# ============================================================
# HEALTH CHECK
# ============================================================

info "Checking /health..."

HEALTH_OK=false

for i in {1..10}; do

    HTTP_CODE="$(
        curl \
            --silent \
            --show-error \
            --output /tmp/virgozki-health.out \
            --write-out '%{http_code}' \
            --connect-timeout 10 \
            --max-time 30 \
            "${SERVICE_URL}/health" \
        || true
    )"

    if [[ "${HTTP_CODE}" == "200" ]]; then
        HEALTH_OK=true
        break
    fi

    warn "Health attempt ${i}/10 failed: HTTP ${HTTP_CODE}"

    sleep 5

done


if [[ "${HEALTH_OK}" != "true" ]]; then

    echo
    warn "Cloud Run /health did not return HTTP 200."

    echo
    echo "Recent Cloud Run logs:"
    gcloud run services logs read "${SERVICE_NAME}" \
        --project="${PROJECT_ID}" \
        --region="${REGION}" \
        --limit=100 \
        || true

    exit 1
fi


# ============================================================
# ROOT / APACHE TEST
# ============================================================

info "Checking Envoy -> Apache fallback..."

ROOT_CODE="$(
    curl \
        --silent \
        --show-error \
        --output /tmp/virgozki-root.out \
        --write-out '%{http_code}' \
        --connect-timeout 10 \
        --max-time 30 \
        "${SERVICE_URL}/" \
    || true
)"

if [[ "${ROOT_CODE}" != "200" ]]; then
    warn "Root path returned HTTP ${ROOT_CODE}"
else
    ok "Envoy -> Apache fallback is responding"
fi


# ============================================================
# FINAL RESULT
# ============================================================

echo
echo "============================================================"
echo " CLOUD RUN TEST COMPLETE"
echo "============================================================"
echo
echo "Service:"
echo "  ${SERVICE_NAME}"
echo
echo "URL:"
echo "  ${SERVICE_URL}"
echo
echo "Public:"
echo "  Envoy :8080"
echo
echo "Internal:"
echo "  HAProxy HTTP :8081"
echo "  Apache       :8083"
echo "  OpenResty    :8084"
echo "  HAProxy gRPC :8086"
echo
echo "Xray:"
echo "  10000-10015"
echo
echo "Health:"
echo "  ${SERVICE_URL}/health"
echo
echo "============================================================"
