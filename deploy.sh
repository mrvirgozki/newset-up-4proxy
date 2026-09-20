#!/bin/bash
set -euo pipefail

BOLD='\033[1m'
RESET='\033[0m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'

ALL_REGIONS=(
"01:asia-east1:Taiwan"
"02:asia-east2:Hong Kong"
"03:asia-northeast1:Japan (Tokyo)"
"04:asia-northeast2:Japan (Osaka)"
"05:asia-northeast3:South Korea (Seoul)"
"06:asia-south1:India (Mumbai)"
"07:asia-south2:India (Delhi)"
"08:asia-southeast1:Singapore"
"09:asia-southeast2:Indonesia (Jakarta)"
"10:australia-southeast1:Australia (Sydney)"
"11:australia-southeast2:Australia (Melbourne)"
"12:europe-central2:Poland (Warsaw)"
"13:europe-north1:Finland"
"14:europe-southwest1:Spain (Madrid)"
"15:europe-west1:Belgium"
"16:europe-west2:United Kingdom (London)"
"17:europe-west3:Germany (Frankfurt)"
"18:europe-west4:Netherlands"
"19:europe-west6:Switzerland (Zurich)"
"20:europe-west8:Italy (Milan)"
"21:europe-west9:France (Paris)"
"22:northamerica-northeast1:Canada (Montreal)"
"23:northamerica-northeast2:Canada (Toronto)"
"24:southamerica-east1:Brazil (Sao Paulo)"
"25:southamerica-west1:Chile (Santiago)"
"26:us-central1:USA (Iowa)"
"27:us-east1:USA (South Carolina)"
"28:us-east4:USA (North Virginia)"
"29:us-east5:USA (Columbus)"
"30:us-south1:USA (Texas)"
"31:us-west1:USA (Oregon)"
"32:us-west2:USA (Los Angeles)"
"33:us-west3:USA (Salt Lake City)"
"34:us-west4:USA (Las Vegas)"
)

clear || true

echo
echo -e "  ${BOLD}${WHITE}VIRGOZKI PANEL • 4 PROXY + gRPC + L7 PROTECTION${RESET}"
echo -e "  ${MAGENTA}OpenResty • HAProxy • Envoy • Apache httpd${RESET}"
echo -e "  ${CYAN}Proxy selection is handled by index.html.${RESET}"
echo -e "  ${CYAN}deploy.sh only builds and deploys the complete stack.${RESET}"
echo

# ============================================================
# CHECK GCP PROJECT
# ============================================================

PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo -e "  ${RED}ERROR: No active GCP project.${RESET}"
    echo -e "  ${YELLOW}Run: gcloud init${RESET}"
    exit 1
fi

echo -e "  ${CYAN}PROJECT:${RESET} ${GREEN}${PROJECT_ID}${RESET}"

# ============================================================
# REGION SELECTION
# ============================================================

REGION="asia-southeast1"

echo
echo -e "  ${CYAN}SELECT REGION (0 = Singapore default):${RESET}"
echo -e "  ${YELLOW}0) ${GREEN}${REGION} (Default)${RESET}"

for item in "${ALL_REGIONS[@]}"; do
    IFS=':' read -r num reg_name country <<< "$item"
    printf "  ${YELLOW}%s) ${GREEN}%-25s ${CYAN}(%s)${RESET}\n" \
        "$num" "$reg_name" "$country"
done

read -r -p "  ${CYAN}REGION NUMBER: ${RESET}" REG_CHOICE

if [[ "$REG_CHOICE" =~ ^[0-9]+$ ]] && [[ "$REG_CHOICE" != "0" ]]; then

    FOUND=0

    for item in "${ALL_REGIONS[@]}"; do
        IFS=':' read -r num reg_name _ <<< "$item"

        if [[ "$num" == "$REG_CHOICE" ]]; then
            REGION="$reg_name"
            FOUND=1
            break
        fi
    done

    if [[ "$FOUND" -eq 0 ]]; then
        echo -e "  ${YELLOW}INVALID REGION NUMBER — USING ${REGION}${RESET}"
    fi
fi

gcloud config set run/region "$REGION" --quiet >/dev/null 2>&1 || true

echo -e "  ${GREEN}Selected region: ${REGION}${RESET}"

# ============================================================
# SERVICE NAME
# ============================================================

read -r -p \
"  ${CYAN}SERVICE NAME [virgozki-panel]: ${RESET}" \
INPUT_NAME

INPUT_NAME=$(echo "$INPUT_NAME" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cd 'a-z0-9-')

SERVICE_NAME=${INPUT_NAME:-virgozki-panel}

if [[ ! "$SERVICE_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo -e "  ${YELLOW}Invalid service name. Using virgozki-panel.${RESET}"
    SERVICE_NAME="virgozki-panel"
fi

echo -e "  ${GREEN}Service: ${SERVICE_NAME}${RESET}"

# ============================================================
# RESOURCE MODE
# ============================================================

CPU="1"
RAM="2Gi"
MAX_INSTANCES="2"
MODE="AUTO"

echo
echo -e "  ${CYAN}SELECT RESOURCE MODE:${RESET}"
echo -e "  ${YELLOW}1) AUTO   ${GREEN}1 vCPU / 2Gi / max 2${RESET}"
echo -e "  ${YELLOW}2) HIGH   ${GREEN}2 vCPU / 4Gi / max 2${RESET}"
echo -e "  ${YELLOW}3) STABLE ${GREEN}4 vCPU / 8Gi / max 1${RESET}"
echo -e "  ${YELLOW}4) CUSTOM${RESET}"

read -r -p "  ${CYAN}MODE [1]: ${RESET}" MODE_CHOICE
MODE_CHOICE=${MODE_CHOICE:-1}

case "$MODE_CHOICE" in

    1)
        CPU="1"
        RAM="2Gi"
        MAX_INSTANCES="2"
        MODE="AUTO"
        ;;

    2)
        CPU="2"
        RAM="4Gi"
        MAX_INSTANCES="2"
        MODE="HIGH"
        ;;

    3)
        CPU="4"
        RAM="8Gi"
        MAX_INSTANCES="1"
        MODE="STABLE"
        ;;

    4)
        read -r -p "  ${CYAN}CPU [1/2/4]: ${RESET}" CPU
        read -r -p "  ${CYAN}RAM [2Gi/4Gi/8Gi]: ${RESET}" RAM
        read -r -p "  ${CYAN}MAX INSTANCES [1-10]: ${RESET}" MAX_INSTANCES
        MODE="CUSTOM"
        ;;

    *)
        echo -e "  ${RED}INVALID RESOURCE MODE${RESET}"
        exit 1
        ;;
esac

echo -e "  ${GREEN}CPU: ${CPU}${RESET}"
echo -e "  ${GREEN}RAM: ${RAM}${RESET}"
echo -e "  ${GREEN}MAX INSTANCES: ${MAX_INSTANCES}${RESET}"

# ============================================================
# FILE CHECK
# ============================================================

echo
echo -e "  ${CYAN}Checking required files...${RESET}"

REQUIRED_FILES=(
    "Dockerfile"
    "config.json"
    "nginx.conf"
    "entrypoint.sh"
    "index.html"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo -e "  ${RED}MISSING FILE: $f${RESET}"
        exit 1
    fi

    echo -e "  ${GREEN}OK:${RESET} $f"
done

# ============================================================
# LOCAL VALIDATION
# ============================================================

echo
echo -e "  ${CYAN}Validating configuration...${RESET}"

python3 -m json.tool config.json >/dev/null

if ! bash -n deploy.sh; then
    echo -e "  ${RED}deploy.sh syntax error${RESET}"
    exit 1
fi

if ! sh -n entrypoint.sh; then
    echo -e "  ${RED}entrypoint.sh syntax error${RESET}"
    exit 1
fi

echo -e "  ${GREEN}JSON validation: OK${RESET}"
echo -e "  ${GREEN}deploy.sh syntax: OK${RESET}"
echo -e "  ${GREEN}entrypoint.sh syntax: OK${RESET}"

# ============================================================
# BUILD
# ============================================================

echo
echo -e "  ${CYAN}========================================${RESET}"
echo -e "  ${CYAN}BUILDING CONTAINER IMAGE${RESET}"
echo -e "  ${CYAN}========================================${RESET}"

IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"

echo -e "  ${CYAN}IMAGE:${RESET} ${GREEN}${IMAGE}${RESET}"

rm -f build.log

if ! gcloud builds submit \
    --tag "$IMAGE" \
    --project "$PROJECT_ID" \
    --quiet >build.log 2>&1
then
    echo
    echo -e "  ${RED}BUILD FAILED${RESET}"
    echo -e "  ${YELLOW}Last 80 lines of build.log:${RESET}"
    tail -n 80 build.log || true
    exit 1
fi

echo -e "  ${GREEN}BUILD SUCCESS${RESET}"

# ============================================================
# CLOUD RUN DEPLOY
# ============================================================

echo
echo -e "  ${CYAN}========================================${RESET}"
echo -e "  ${CYAN}DEPLOYING TO CLOUD RUN${RESET}"
echo -e "  ${CYAN}========================================${RESET}"

rm -f deploy.log

# IMPORTANT:
# Do NOT use --use-http2 here.
#
# Cloud Run receives normal HTTP/1.1 traffic at the public container
# interface while the internal Envoy/OpenResty/HAProxy/Apache layers
# handle the required gRPC/HTTP2 traffic.
#
# WebSocket support and native gRPC remain available through the
# application-level proxy configuration.

if ! gcloud run deploy "$SERVICE_NAME" \
    --image "$IMAGE" \
    --platform managed \
    --region "$REGION" \
    --cpu "$CPU" \
    --memory "$RAM" \
    --port 8080 \
    --concurrency 800 \
    --timeout 3600 \
    --min-instances 0 \
    --max-instances "$MAX_INSTANCES" \
    --session-affinity \
    --allow-unauthenticated \
    --project "$PROJECT_ID" \
    --quiet >deploy.log 2>&1
then
    echo
    echo -e "  ${RED}CLOUD RUN DEPLOYMENT FAILED${RESET}"
    echo -e "  ${YELLOW}Last 80 lines of deploy.log:${RESET}"
    tail -n 80 deploy.log || true
    exit 1
fi

echo -e "  ${GREEN}CLOUD RUN DEPLOYMENT SUCCESS${RESET}"

# ============================================================
# GET SERVICE URL
# ============================================================

echo
echo -e "  ${CYAN}Checking Cloud Run service...${RESET}"

SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
    --region "$REGION" \
    --project "$PROJECT_ID" \
    --format='value(status.url)')

if [[ -z "$SERVICE_URL" ]]; then
    echo -e "  ${RED}ERROR: Cloud Run URL was not returned.${RESET}"
    exit 1
fi

HOST=$(echo "$SERVICE_URL" | sed 's|https://||')

echo -e "  ${GREEN}SERVICE URL:${RESET} ${SERVICE_URL}"

# ============================================================
# BASIC HEALTH CHECK
# ============================================================

echo
echo -e "  ${CYAN}Running public endpoint check...${RESET}"

HTTP_CODE=$(curl \
    -L \
    -k \
    -sS \
    -o /tmp/virgozki-health.html \
    -w '%{http_code}' \
    --max-time 30 \
    "$SERVICE_URL/" 2>/dev/null || true)

if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "  ${GREEN}PUBLIC PANEL CHECK: HTTP ${HTTP_CODE} OK${RESET}"
else
    echo -e "  ${YELLOW}PUBLIC PANEL CHECK: HTTP ${HTTP_CODE}${RESET}"
    echo -e "  ${YELLOW}The service is deployed, but the panel did not return HTTP 200.${RESET}"
    echo -e "  ${YELLOW}Check Cloud Run logs if necessary.${RESET}"
fi

rm -f /tmp/virgozki-health.html

# ============================================================
# CONNECTION INFO
# ============================================================

cat > connection-info.txt <<INFO
VIRGOZKI 4-PROXY + gRPC
========================

SERVICE
-------
Name   : ${SERVICE_NAME}
Project: ${PROJECT_ID}
Region : ${REGION}
Mode   : ${MODE}
CPU    : ${CPU}
RAM    : ${RAM}
Max    : ${MAX_INSTANCES}

PUBLIC URL
----------
${SERVICE_URL}

PANEL
-----
${SERVICE_URL}/

PROXY ENGINE PREFIXES
---------------------
OpenResty : /openresty/
HAProxy   : /haproxy/
Envoy     : /envoy/
Apache    : /apache/

TRANSPORTS
----------
WebSocket
HTTP Upgrade
XHTTP
gRPC

IMPORTANT
---------
Proxy selection is handled by index.html.

deploy.sh does not select a proxy engine.
All four proxy engines are deployed together.

The public Envoy router selects the engine
according to the prefix generated by index.html.

CLOUD RUN
---------
Container port: 8080
Concurrency   : 800
Timeout       : 3600 seconds
Min instances : 0
Max instances : ${MAX_INSTANCES}
Session affinity: enabled

HTTP/2
------
--use-http2 is intentionally NOT enabled on Cloud Run.

Native gRPC handling is provided by the internal
proxy stack and Envoy/OpenResty/HAProxy/Apache
configuration.

FILES
-----
Dockerfile
config.json
nginx.conf
entrypoint.sh
index.html
deploy.sh

DEPLOYED
--------
$(date '+%Y-%m-%d %H:%M:%S')
INFO

# ============================================================
# FINAL STATUS
# ============================================================

echo
echo -e "  ${GREEN}========================================${RESET}"
echo -e "  ${GREEN}        DEPLOY SUCCESS${RESET}"
echo -e "  ${GREEN}========================================${RESET}"
echo
echo -e "  ${CYAN}URL:${RESET}     ${GREEN}${SERVICE_URL}${RESET}"
echo -e "  ${CYAN}REGION:${RESET}  ${GREEN}${REGION}${RESET}"
echo -e "  ${CYAN}MODE:${RESET}    ${GREEN}${MODE}${RESET}"
echo -e "  ${CYAN}CPU:${RESET}     ${GREEN}${CPU}${RESET}"
echo -e "  ${CYAN}RAM:${RESET}     ${GREEN}${RAM}${RESET}"
echo -e "  ${CYAN}MAX:${RESET}     ${GREEN}${MAX_INSTANCES}${RESET}"
echo
echo -e "  ${CYAN}PROXIES:${RESET}"
echo -e "  ${GREEN}OpenResty | HAProxy | Envoy | Apache${RESET}"
echo
echo -e "  ${CYAN}TRANSPORTS:${RESET}"
echo -e "  ${GREEN}WebSocket | HTTP Upgrade | XHTTP | gRPC${RESET}"
echo
echo -e "  ${CYAN}INFO:${RESET} ${GREEN}connection-info.txt${RESET}"
echo
echo -e "  ${GREEN}========================================${RESET}"
echo
