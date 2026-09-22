#!/bin/bash
set -euo pipefail

# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN
# DEBIAN BOOKWORM
#
# PUBLIC:
#   Cloud Run -> Envoy :8080
#
# INTERNAL:
#   HAProxy HTTP :8081
#   HAProxy gRPC :8086
#   OpenResty    :8084
#   Apache       :8083
#   Xray         :10000-10015
#
# IMPORTANT:
#   DEPLOY=false by default
#
#   BUILD / VALIDATION ONLY:
#       ./deploy.sh
#
#   ACTUAL DEPLOYMENT:
#       DEPLOY=true ./deploy.sh
#
# NOTE:
#   No --use-http2 is forced at Cloud Run level because
#   this service also supports WebSocket / HTTPUpgrade / XHTTP.
# ============================================================


# ============================================================
# COLORS
# ============================================================

BOLD='\033[1m'
RESET='\033[0m'

GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'


# ============================================================
# CONFIGURATION
# ============================================================

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')}"

REGION="${REGION:-us-central1}"

SERVICE_NAME="${SERVICE_NAME:-virgozki-4proxy}"

REPOSITORY="${REPOSITORY:-virgozki}"

IMAGE_NAME="${IMAGE_NAME:-virgozki}"

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${IMAGE_NAME}:latest"

DEPLOY="${DEPLOY:-false}"


# ============================================================
# CLOUD RUN RESOURCES
# ============================================================

CPU="${CPU:-2}"
RAM="${RAM:-4Gi}"

MAX_INSTANCES="${MAX_INSTANCES:-4}"

CONCURRENCY="${CONCURRENCY:-80}"

TIMEOUT="${TIMEOUT:-3600}"


# ============================================================
# FUNCTIONS
# ============================================================

loading() {

    local text="$1"
    local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    for ((i=0; i<2; i++)); do

        for ((j=0; j<${#spinner}; j++)); do

            echo -ne "\r  ${CYAN}${spinner:$j:1} ${text}...${RESET}"

            sleep 0.05

        done

    done

    echo -ne "\r  ${GREEN}DONE: ${text}${RESET}\n"
}


info() {
    echo -e "  ${CYAN}[INFO]${RESET} $1"
}


ok() {
    echo -e "  ${GREEN}[ OK ]${RESET} $1"
}


warn() {
    echo -e "  ${YELLOW}[WARN]${RESET} $1"
}


fail() {
    echo -e "  ${RED}[FAIL]${RESET} $1"
    exit 1
}


# ============================================================
# HEADER
# ============================================================

clear

echo
echo -e "  ${BOLD}${WHITE}VIRGOZKI 4-PROXY + gRPC${RESET}"
echo -e "  ${MAGENTA}CLOUD RUN • DEBIAN BOOKWORM${RESET}"
echo

echo -e "  ${GREEN}PUBLIC:${RESET}"
echo -e "    Cloud Run -> Envoy :8080"

echo
echo -e "  ${GREEN}INTERNAL:${RESET}"
echo -e "    HAProxy HTTP :8081"
echo -e "    HAProxy gRPC :8086"
echo -e "    OpenResty    :8084"
echo -e "    Apache       :8083"

echo
echo -e "  ${GREEN}XRAY:${RESET}"
echo -e "    :10000-10015"

echo


# ============================================================
# PROJECT CHECK
# ============================================================

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "(unset)" ]]; then
    fail "No active GCP project detected."
fi

echo -e "  ${CYAN}PROJECT:${RESET} ${GREEN}${PROJECT_ID}${RESET}"
echo -e "  ${CYAN}REGION:${RESET}  ${GREEN}${REGION}${RESET}"
echo -e "  ${CYAN}SERVICE:${RESET} ${GREEN}${SERVICE_NAME}${RESET}"
echo -e "  ${CYAN}DEPLOY:${RESET}  ${GREEN}${DEPLOY}${RESET}"
echo

gcloud projects describe "${PROJECT_ID}" >/dev/null 2>&1 \
    || fail "Cannot access GCP project: ${PROJECT_ID}"

ok "GCP project accessible"


# ============================================================
# COMMAND CHECK
# ============================================================

loading "CHECKING REQUIRED COMMANDS"

for cmd in gcloud curl python3; do

    command -v "${cmd}" >/dev/null 2>&1 \
        || fail "Required command not found: ${cmd}"

    ok "${cmd} available"

done


# ============================================================
# DEPLOY VALUE CHECK
# ============================================================

if [[ "${DEPLOY}" != "true" && "${DEPLOY}" != "false" ]]; then

    fail "DEPLOY must be either true or false."

fi


# ============================================================
# REQUIRED FILES
# ============================================================

loading "CHECKING REQUIRED FILES"

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

for file in "${REQUIRED_FILES[@]}"; do

    if [[ ! -f "${file}" ]]; then
        fail "Missing file: ${file}"
    fi

    ok "Found ${file}"

done


# ============================================================
# CONFIG.JSON VALIDATION
# ============================================================

loading "CHECKING config.json"

python3 - <<'PY'
import json
import sys

try:
    with open("config.json", "r", encoding="utf-8") as f:
        json.load(f)

    print("  [ OK ] config.json is valid JSON")

except Exception as e:
    print("  [FAIL] config.json is invalid")
    print(e)
    sys.exit(1)
PY


# ============================================================
# DOCKERFILE VALIDATION
# ============================================================

loading "CHECKING DOCKERFILE"

grep -q '^FROM envoyproxy/envoy:v1.39.1 AS envoy' Dockerfile \
    || fail "Envoy base image missing"

grep -q '^FROM ghcr.io/xtls/xray-core:25.12.8 AS xray' Dockerfile \
    || fail "Xray base image missing"

grep -q '^FROM openresty/openresty:1.31.1.1-bookworm-fat AS final' Dockerfile \
    || fail "OpenResty base image missing"

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
# SUPERVISOR VALIDATION
# ============================================================

loading "CHECKING SUPERVISOR CONFIGURATION"

grep -q 'xray run -c /etc/xray/config.json' supervisord.conf \
    || fail "Xray Supervisor command missing"

grep -q 'apachectl -DFOREGROUND' supervisord.conf \
    || fail "Apache Supervisor command missing"

grep -q 'haproxy -W -db -f /etc/haproxy/haproxy.cfg' supervisord.conf \
    || fail "HAProxy Supervisor command missing"

grep -q 'openresty -c /etc/openresty/nginx.conf' supervisord.conf \
    || fail "OpenResty config path missing"

grep -q 'envoy -c /etc/envoy/envoy.yaml' supervisord.conf \
    || fail "Envoy Supervisor command missing"

ok "Supervisor configuration looks correct"


# ============================================================
# PORT ALIGNMENT
# ============================================================

loading "CHECKING PORT ALIGNMENT"

grep -q 'port_value: 8080' envoy.yaml \
    || fail "Envoy :8080 missing"

grep -q 'Listen 127.0.0.1:8083' httpd.conf \
    || fail "Apache :8083 missing"

grep -q 'bind 127.0.0.1:8081' haproxy.cfg \
    || fail "HAProxy HTTP :8081 missing"

grep -q 'bind 127.0.0.1:8086' haproxy.cfg \
    || fail "HAProxy gRPC :8086 missing"

grep -q 'listen 127.0.0.1:8084' nginx.conf \
    || fail "OpenResty :8084 missing"

ok "Internal port alignment looks correct"


# ============================================================
# OLD PORT COLLISION CHECK
# ============================================================

info "Checking HAProxy/OpenResty port collision..."

if grep -Eq '^[[:space:]]*bind[[:space:]]+127\.0\.0\.1:8084' haproxy.cfg; then

    fail "HAProxy still uses :8084. OpenResty also uses :8084."

fi

ok "No HAProxy/OpenResty :8084 collision"


# ============================================================
# gRPC PATH VALIDATION
# ============================================================

loading "CHECKING gRPC PATHS"

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

    ok "gRPC aligned: ${path}"

done


# ============================================================
# XRAY PORT VALIDATION
# ============================================================

loading "CHECKING XRAY PORTS"

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
        || fail "Xray port missing in config.json: ${port}"

    grep -q "port_value: ${port}" envoy.yaml \
        || fail "Xray port missing in envoy.yaml: ${port}"

done

ok "Xray ports 10000-10015 aligned"


# ============================================================
# HEALTH ROUTES
# ============================================================

loading "CHECKING HEALTH ROUTES"

grep -q '/health' envoy.yaml \
    || fail "Envoy /health missing"

grep -q '/health' nginx.conf \
    || fail "OpenResty /health missing"

grep -q '/health' httpd.conf \
    || fail "Apache /health missing"

ok "Health routes found"


# ============================================================
# PUBLIC LISTENER
# ============================================================

info "Checking public Envoy listener..."

grep -q 'port_value: 8080' envoy.yaml \
    || fail "Envoy public listener :8080 missing"

ok "Public Envoy listener is :8080"


# ============================================================
# ENABLE GOOGLE CLOUD APIS
# ============================================================

loading "ENABLING REQUIRED GOOGLE CLOUD APIS"

gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --project="${PROJECT_ID}"

ok "Required APIs enabled"


# ============================================================
# ARTIFACT REGISTRY
# ============================================================

info "Checking Artifact Registry..."

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
    --tag="${IMAGE}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}"

ok "Container image built successfully"


# ============================================================
# BUILD ONLY MODE
# ============================================================

if [[ "${DEPLOY}" != "true" ]]; then

    echo
    echo "============================================================"
    echo -e " ${GREEN}BUILD / VALIDATION COMPLETE${RESET}"
    echo "============================================================"
    echo

    echo -e "  ${CYAN}IMAGE:${RESET}"
    echo "  ${IMAGE}"

    echo
    echo -e "  ${YELLOW}CLOUD RUN DEPLOYMENT WAS NOT PERFORMED.${RESET}"

    echo
    echo "  This is intentional because:"
    echo
    echo "    DEPLOY=${DEPLOY}"
    echo

    echo "  Kapag ready ka na:"
    echo
    echo "    DEPLOY=true ./deploy.sh"
    echo

    echo "============================================================"

    exit 0

fi


# ============================================================
# CLOUD RUN DEPLOYMENT
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
    --max-instances="${MAX_INSTANCES}" \
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

CLEAN_HOST="${SERVICE_URL#https://}"

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

        ok "Cloud Run -> Envoy /health passed"

        break

    fi

    warn "Health attempt ${i}/10 failed: HTTP ${HTTP_CODE}"

    sleep 5

done


# ============================================================
# HEALTH FAILURE
# ============================================================

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
# APACHE FALLBACK TEST
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

if [[ "${ROOT_CODE}" == "200" ]]; then

    ok "Envoy -> Apache fallback is responding"

else

    warn "Root path returned HTTP ${ROOT_CODE}"

fi


# ============================================================
# FINAL
# ============================================================

echo
echo "============================================================"
echo -e " ${GREEN}CLOUD RUN DEPLOYMENT COMPLETE${RESET}"
echo "============================================================"
echo

echo -e "  ${CYAN}SERVICE:${RESET} ${GREEN}${SERVICE_NAME}${RESET}"
echo -e "  ${CYAN}REGION:${RESET}  ${GREEN}${REGION}${RESET}"
echo -e "  ${CYAN}URL:${RESET}     ${GREEN}${SERVICE_URL}${RESET}"

echo
echo "Public:"
echo "  Cloud Run -> Envoy :8080"

echo
echo "Internal:"
echo "  HAProxy HTTP :8081"
echo "  HAProxy gRPC :8086"
echo "  OpenResty    :8084"
echo "  Apache       :8083"

echo
echo "Xray:"
echo "  :10000-10015"

echo
echo "Health:"
echo "  ${SERVICE_URL}/health"

echo
echo "============================================================"
