#!/bin/bash
set -euo pipefail

# ============================================================
# VIRGOZKI 4-PROXY + gRPC | CLOUD RUN DEPLOY
# FINAL ARCHITECTURE:
#
# Cloud Run Public → Envoy :8080 (MAIN)
#                      ↳ Routing / gRPC / WS / HU / XHTTP
#                      ↳ Xray :10000-10015
#                      ↳ Apache :8083
#
# OpenResty :8084 & HAProxy :8081/:8084 = INTERNAL ONLY
#
# Supervisor manages: Xray / Apache / Envoy / HAProxy / OpenResty / anti_ddos
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


# ============================================================
# GCP REGIONS
# ============================================================
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
echo -e "${BOLD}${CYAN}==================================================${RESET}"
echo -e "${BOLD}${CYAN}       VIRGOZKI 4-PROXY + gRPC DEPLOY${RESET}"
echo -e "${BOLD}${CYAN}==================================================${RESET}"
echo


# ============================================================
# 1. CHECK GCP PROJECT
# ============================================================
PROJECT_ID="$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')"

if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo -e "${RED}❌ WALANG GCP PROJECT.${RESET}"
    echo
    echo -e "${YELLOW}I-run muna:${RESET}"
    echo "gcloud init"
    echo
    exit 1
fi

echo -e "${CYAN}GCP PROJECT:${RESET} ${GREEN}${PROJECT_ID}${RESET}"
echo


# ============================================================
# 2. PILIIN ANG REGION
# ============================================================
REGION="asia-southeast1"

echo -e "${CYAN}==================================================${RESET}"
echo -e "${CYAN}PILIIN ANG CLOUD RUN REGION${RESET}"
echo -e "${CYAN}==================================================${RESET}"
echo -e "${YELLOW}0) ${GREEN}${REGION} (Singapore - RECOMMENDED)${RESET}"
echo

for item in "${ALL_REGIONS[@]}"; do
    IFS=':' read -r num reg country <<< "$item"
    printf "${YELLOW}%s) ${GREEN}%-25s ${CYAN}(%s)${RESET}\n" "$num" "$reg" "$country"
done

echo
read -rp "Ilagay ang numero [0]: " REG_CHOICE
REG_CHOICE="${REG_CHOICE:-0}"

if [[ "$REG_CHOICE" == "0" ]]; then
    REGION="asia-southeast1"
elif [[ "$REG_CHOICE" =~ ^[0-9]+$ ]]; then
    FOUND_REGION=""
    for item in "${ALL_REGIONS[@]}"; do
        IFS=':' read -r num reg _ <<< "$item"
        if [[ "$num" == "$REG_CHOICE" ]]; then
            FOUND_REGION="$reg"
            break
        fi
    done
    if [[ -z "$FOUND_REGION" ]]; then
        echo -e "${RED}❌ INVALID REGION NUMBER.${RESET}"
        exit 1
    fi
    REGION="$FOUND_REGION"
else
    echo -e "${RED}❌ INVALID REGION SELECTION.${RESET}"
    exit 1
fi

gcloud config set run/region "$REGION" --quiet >/dev/null
echo
echo -e "${GREEN}✅ REGION: ${REGION}${RESET}"
echo


# ============================================================
# 3. SERVICE NAME
# ============================================================
read -rp "Pangalan ng service [virgozki-panel]: " INPUT_NAME
INPUT_NAME="$(echo "$INPUT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
SERVICE_NAME="${INPUT_NAME:-virgozki-panel}"

if [[ ! "$SERVICE_NAME" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo -e "${RED}❌ INVALID SERVICE NAME.${RESET}"
    echo -e "${YELLOW}Gagamitin ang default: virgozki-panel${RESET}"
    SERVICE_NAME="virgozki-panel"
fi

echo -e "${GREEN}SERVICE: ${SERVICE_NAME}${RESET}"
echo


# ============================================================
# 4. CPU / RAM PROFILE
# ============================================================
echo -e "${CYAN}==================================================${RESET}"
echo -e "${CYAN}PILIIN ANG SERVER PROFILE${RESET}"
echo -e "${CYAN}==================================================${RESET}"
echo -e "${YELLOW}1) ${GREEN}PINAKAMURA${RESET}       — 1 vCPU / 1Gi RAM"
echo -e "${YELLOW}2) ${GREEN}NORMAL${RESET}           — 1 vCPU / 2Gi RAM"
echo -e "${YELLOW}3) ${GREEN}MABILIS${RESET}          — 2 vCPU / 4Gi RAM"
echo -e "${YELLOW}4) ${GREEN}MATATAG${RESET}          — 4 vCPU / 8Gi RAM"
echo -e "${YELLOW}5) ${GREEN}PINAKA-MALAKAS${RESET}  — 8 vCPU / 16Gi RAM"
echo

read -rp "Ilagay ang numero [2]: " MODE
MODE="${MODE:-2}"

case "$MODE" in
    1) CPU="1"; RAM="1Gi"; MAX_INST="3"; DESC="PINAKAMURA" ;;
    2) CPU="1"; RAM="2Gi"; MAX_INST="2"; DESC="NORMAL" ;;
    3) CPU="2"; RAM="4Gi"; MAX_INST="2"; DESC="MABILIS" ;;
    4) CPU="4"; RAM="8Gi"; MAX_INST="1"; DESC="MATATAG" ;;
    5) CPU="8"; RAM="16Gi"; MAX_INST="1"; DESC="PINAKA-MALAKAS" ;;
    *) echo -e "${RED}❌ INVALID SERVER PROFILE.${RESET}"; exit 1 ;;
esac

echo
echo -e "${GREEN}✅ PROFILE: ${DESC}${RESET}"
echo -e "${GREEN}CPU: ${CPU} vCPU${RESET}"
echo -e "${GREEN}RAM: ${RAM}${RESET}"
echo -e "${GREEN}MAX INSTANCES: ${MAX_INST}${RESET}"
echo


# ============================================================
# 5. CHECK REQUIRED FILES
# ============================================================
echo -e "${CYAN}==================================================${RESET}"
echo -e "${CYAN}CHECKING PROJECT FILES${RESET}"
echo -e "${CYAN}==================================================${RESET}"

REQUIRED_FILES=(
    "Dockerfile"
    "supervisord.conf"
    "nginx.conf"
    "haproxy.cfg"
    "envoy.yaml"
    "httpd.conf"
    "index.html"
    "config.json"
    "anti_ddos.py"
)

for FILE in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "$FILE" ]]; then
        echo -e "${RED}❌ KULANG ANG FILE: ${FILE}${RESET}"
        exit 1
    fi
    echo -e "${GREEN}✓ ${FILE}${RESET}"
done


# ============================================================
# 6. CHECK config.json SYNTAX
# ============================================================
echo
echo -e "${CYAN}Checking config.json...${RESET}"
if ! python3 -m json.tool config.json >/dev/null 2>&1; then
    echo -e "${RED}❌ MALI ANG config.json${RESET}"
    exit 1
fi
echo -e "${GREEN}✓ config.json OK${RESET}"


# ============================================================
# 7. CHECK DOCKERFILE
# ============================================================
echo
echo -e "${CYAN}Checking Dockerfile...${RESET}"
if ! grep -qE '^[[:space:]]*FROM[[:space:]]+' Dockerfile; then
    echo -e "${RED}❌ Walang valid FROM sa Dockerfile.${RESET}"
    exit 1
fi
echo -e "${GREEN}✓ Dockerfile basic check OK${RESET}"


# ============================================================
# 8. CHECK DOCKERFILE COPY STEPS
# ============================================================
echo
echo -e "${CYAN}Checking Dockerfile configuration...${RESET}"
for FILE in \
    "supervisord.conf" "config.json" "nginx.conf" "haproxy.cfg" \
    "envoy.yaml" "httpd.conf" "index.html" "anti_ddos.py"
do
    if ! grep -qE "^[[:space:]]*COPY[[:space:]].*${FILE}([[:space:]]|$|/etc/)" Dockerfile; then
        echo -e "${YELLOW}⚠️  WARNING: ${FILE} might be missing in COPY steps${RESET}"
    fi
done
echo -e "${GREEN}✓ Dockerfile COPY checks OK${RESET}"


# ============================================================
# 9. ENABLE REQUIRED APIS
# ============================================================
echo
echo -e "${CYAN}Checking Google Cloud APIs...${RESET}"
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --project="$PROJECT_ID" --quiet
echo -e "${GREEN}✓ Required APIs enabled${RESET}"


# ============================================================
# 10. ARTIFACT REGISTRY
# ============================================================
AR_REPO="virgozki"
AR_LOCATION="$REGION"
IMAGE_NAME="$SERVICE_NAME"
IMAGE="${AR_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:latest"

echo
echo -e "${CYAN}==================================================${RESET}"
echo -e "${CYAN}CHECKING ARTIFACT REGISTRY${RESET}"
echo -e "${CYAN}==================================================${RESET}"

if ! gcloud artifacts repositories describe "$AR_REPO" --location="$AR_LOCATION" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo -e "${YELLOW}Repository '${AR_REPO}' not found. Creating...${RESET}"
    gcloud artifacts repositories create "$AR_REPO" \
        --repository-format=docker --location="$AR_LOCATION" \
        --description="VIRGOZKI Docker images" --project="$PROJECT_ID" --quiet
    echo -e "${GREEN}✓ Artifact Registry created${RESET}"
else
    echo -e "${GREEN}✓ Artifact Registry already exists${RESET}"
fi

echo
echo -e "${CYAN}IMAGE:${RESET}"
echo -e "${GREEN}${IMAGE}${RESET}"
echo


# ============================================================
# 11. BUILD IMAGE
# ============================================================
echo -e "${CYAN}==================================================${RESET}"
echo -e "${CYAN}BUILDING CONTAINER IMAGE${RESET}"
echo -e "${CYAN}==================================================${RESET}"

if ! gcloud builds submit --tag "$IMAGE" --project="$PROJECT_ID" --region="$REGION"; then
    echo -e "${RED}❌ CLOUD BUILD FAILED${RESET}"
    exit 1
fi

echo
echo -e "${GREEN}==================================================${RESET}"
echo -e "${GREEN}IMAGE BUILD SUCCESSFUL ✅${RESET}"
echo -e "${GREEN}==================================================${RESET}"
echo


# ============================================================
# 12. DEPLOY CLOUD RUN
# ============================================================
echo -e "${CYAN}==================================================${RESET}"
echo -e "${CYAN}DEPLOYING TO CLOUD RUN${RESET}"
echo -e "${CYAN}==================================================${RESET}"

echo -e "${YELLOW}Cloud Run settings:${RESET}"
echo -e "  Port          : 8080 (ENVOY MAIN)"
echo -e "  HTTP/2        : ENABLED"
echo -e "  Concurrency   : 80"
echo -e "  Timeout       : 3600s"
echo -e "  Min instances : 0"
echo -e "  Max instances : ${MAX_INST}"
echo

if ! gcloud run deploy "$SERVICE_NAME" \
    --image "$IMAGE" --platform managed --project="$PROJECT_ID" --region="$REGION" \
    --cpu="$CPU" --memory="$RAM" --port=8080 --use-http2 \
    --concurrency=80 --timeout=3600 --min-instances=0 --max-instances="$MAX_INST" \
    --session-affinity --allow-unauthenticated --quiet; then
    echo -e "${RED}❌ CLOUD RUN DEPLOY FAILED${RESET}"
    exit 1
fi


# ============================================================
# 13. GET SERVICE URL
# ============================================================
echo
echo -e "${CYAN}Getting Cloud Run service URL...${RESET}"
SERVICE_URL="$(gcloud run services describe "$SERVICE_NAME" --platform managed \
    --project="$PROJECT_ID" --region="$REGION" --format='value(status.url)')"

if [[ -z "$SERVICE_URL" ]]; then
    echo -e "${RED}❌ Hindi makuha ang service URL.${RESET}"
    exit 1
fi


# ============================================================
# 14. HEALTH CHECK
# ============================================================
echo
echo -e "${YELLOW}Waiting for service to start...${RESET}"
sleep 8

echo -e "${CYAN}Checking /health...${RESET}"
HEALTH_OK="false"
for ATTEMPT in {1..8}; do
    if curl -fsS --connect-timeout 10 --max-time 30 "${SERVICE_URL}/health" >/dev/null 2>&1; then
        HEALTH_OK="true"
        break
    fi
    echo -e "${YELLOW}Attempt ${ATTEMPT}/8 failed. Retrying...${RESET}"
    sleep 5
done

if [[ "$HEALTH_OK" != "true" ]]; then
    echo -e "${RED}❌ DEPLOYED BUT HEALTH CHECK FAILED!${RESET}"
    echo -e "${YELLOW}URL: ${SERVICE_URL}${RESET}"
    echo -e "${YELLOW}Check logs: gcloud run services logs read ${SERVICE_NAME} --region ${REGION}${RESET}"
    exit 1
fi
echo -e "${GREEN}✓ /health OK${RESET}"


# ============================================================
# 15. FINAL SUMMARY
# ============================================================
echo
echo -e "${GREEN}==================================================${RESET}"
echo -e "${GREEN}        VIRGOZKI DEPLOYMENT SUCCESSFUL ✅${RESET}"
echo -e "${GREEN}==================================================${RESET}"
echo
echo -e "${CYAN}PROJECT       :${RESET} ${PROJECT_ID}"
echo -e "${CYAN}SERVICE       :${RESET} ${SERVICE_NAME}"
echo -e "${CYAN}REGION        :${RESET} ${REGION}"
echo -e "${CYAN}PROFILE       :${RESET} ${DESC}"
echo -e "${CYAN}CPU/RAM       :${RESET} ${CPU} vCPU / ${RAM}"
echo -e "${CYAN}PORT          :${RESET} 8080 (Envoy)"
echo -e "${CYAN}TIMEOUT       :${RESET} 3600s"
echo
echo -e "${CYAN}FLOW:${RESET}"
echo -e "${GREEN}Cloud Run → Envoy :8080 → Xray / Apache${RESET}"
echo
echo -e "${CYAN}SERVICE URL:${RESET}"
echo -e "${BOLD}${GREEN}${SERVICE_URL}${RESET}"
echo
echo -e "${CYAN}HEALTH:${RESET}"
echo -e "${GREEN}${SERVICE_URL}/health${RESET}"
echo
echo -e "${GREEN}READY! 🚀${RESET}"
echo
 p
