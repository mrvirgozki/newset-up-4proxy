#!/bin/bash
set -euo pipefail

# --------------------------
# KULAY PARA MADALI BASAHIN
# --------------------------
BOLD='\033[1m'
RESET='\033[0m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'

# --------------------------
# LISTA NG GCP REGION
# --------------------------
ALL_REGIONS=(
"01:asia-east1:Taiwan" "02:asia-east2:Hong Kong" "03:asia-northeast1:Japan (Tokyo)"
"04:asia-northeast2:Japan (Osaka)" "05:asia-northeast3:South Korea (Seoul)"
"06:asia-south1:India (Mumbai)" "07:asia-south2:India (Delhi)" "08:asia-southeast1:Singapore"
"09:asia-southeast2:Indonesia (Jakarta)" "10:australia-southeast1:Australia (Sydney)"
"11:australia-southeast2:Australia (Melbourne)" "12:europe-central2:Poland (Warsaw)"
"13:europe-north1:Finland" "14:europe-southwest1:Spain (Madrid)" "15:europe-west1:Belgium"
"16:europe-west2:United Kingdom (London)" "17:europe-west3:Germany (Frankfurt)"
"18:europe-west4:Netherlands" "19:europe-west6:Switzerland (Zurich)" "20:europe-west8:Italy (Milan)"
"21:europe-west9:France (Paris)" "22:northamerica-northeast1:Canada (Montreal)"
"23:northamerica-northeast2:Canada (Toronto)" "24:southamerica-east1:Brazil (Sao Paulo)"
"25:southamerica-west1:Chile (Santiago)" "26:us-central1:USA (Iowa)"
"27:us-east1:USA (South Carolina)" "28:us-east4:USA (North Virginia)" "29:us-east5:USA (Columbus)"
"30:us-south1:USA (Texas)" "31:us-west1:USA (Oregon)" "32:us-west2:USA (Los Angeles)"
"33:us-west3:USA (Salt Lake City)" "34:us-west4:USA (Las Vegas)"
)

clear || true
echo -e "\n${BOLD}${CYAN}=== VIRGOZKI 4-PROXY + gRPC DEPLOY ===${RESET}\n"

# --------------------------
# 1. CHECK GCP PROJECT
# --------------------------
PROJECT_ID=$(gcloud config get-value project 2>/dev/null | tr -d '[:space:]')
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
    echo -e "${RED}❌ WALANG GCP PROJECT! I-run muna ang 'gcloud init'${RESET}"
    exit 1
fi
echo -e "${CYAN}Project: ${GREEN}${PROJECT_ID}${RESET}\n"

# --------------------------
# 2. PILIH REGION (DEFAULT SINGAPORE)
# --------------------------
REGION="asia-southeast1"
echo -e "${CYAN}PILIH LOKASYON (0 = DEFAULT SINGAPORE):${RESET}"
echo -e "${YELLOW}0) ${GREEN}${REGION} (Pinakamabilis para sa Pilipinas)${RESET}"
for item in "${ALL_REGIONS[@]}"; do
    IFS=':' read -r num reg country <<< "$item"
    printf "${YELLOW}%s) ${GREEN}%-25s ${CYAN}(%s)${RESET}\n" "$num" "$reg" "$country"
done
read -rp "Ilagay ang numero: " REG_CHOICE
if [[ "$REG_CHOICE" =~ ^[0-9]+$ && "$REG_CHOICE" != "0" ]]; then
    for item in "${ALL_REGIONS[@]}"; do
        IFS=':' read -r num reg _ <<< "$item"
        [[ "$num" == "$REG_CHOICE" ]] && { REGION="$reg"; break; }
    done
fi
gcloud config set run/region "$REGION" --quiet >/dev/null
echo -e "\n${GREEN}Napili: ${REGION}${RESET}\n"

# --------------------------
# 3. PANGALAN NG SERVICE
# --------------------------
read -rp "Pangalan ng service [virgozki-panel]: " INPUT_NAME
INPUT_NAME=$(echo "$INPUT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
SERVICE_NAME=${INPUT_NAME:-virgozki-panel}
[[ ! "$SERVICE_NAME" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] && SERVICE_NAME="virgozki-panel"
echo -e "${GREEN}Pangalan: ${SERVICE_NAME}${RESET}\n"

# --------------------------
# 4. CPU AT RAM — 5 PAGPIPILIAN! 🎯
# --------------------------
echo -e "${CYAN}=== PILIIN ANG KLASE NG SERVER ===${RESET}"
echo -e "${YELLOW}1) ${GREEN}PINAKAMURA${CYAN} — 1 CPU / 1GB RAM — Ikaw lang gagamitin, tipid sa gastos${RESET}"
echo -e "${YELLOW}2) ${GREEN}NORMAL${CYAN} — 1 CPU / 2GB RAM — Pangkalahatan, balanse at matipid${RESET}"
echo -e "${YELLOW}3) ${GREEN}MABILIS${CYAN} — 2 CPU / 4GB RAM — Maraming gumagamit, mabilis ang koneksyon${RESET}"
echo -e "${YELLOW}4) ${GREEN}MATATAG${CYAN} — 4 CPU / 8GB RAM — Sobrang daming tao, walang lag o putol${RESET}"
echo -e "${YELLOW}5) ${GREEN}PINAKA-MALAKAS${CYAN} — 8 CPU / 16GB RAM — Streaming/Video/High Traffic lang${RESET}"
read -rp "Ilagay ang numero [2]: " MODE

# Awtomatikong itatakda ang lahat depende sa pinili mo
case "${MODE:-2}" in
    1) CPU="1";  RAM="1Gi";  MAX_INST=3; DESC="PINAKAMURA" ;;
    2) CPU="1";  RAM="2Gi";  MAX_INST=2; DESC="NORMAL" ;;
    3) CPU="2";  RAM="4Gi";  MAX_INST=2; DESC="MABILIS" ;;
    4) CPU="4";  RAM="8Gi";  MAX_INST=1; DESC="MATATAG" ;;
    5) CPU="8";  RAM="16Gi"; MAX_INST=1; DESC="PINAKA-MALAKAS" ;;
esac

echo -e "${GREEN}Napili: ${DESC} — ${CPU} CPU / ${RAM} RAM${RESET}\n"

# --------------------------
# 5. CHECK KUNG KOMPLETO ANG FILES
# --------------------------
echo -e "${CYAN}Sinusuri ang mga files...${RESET}"
REQUIRED=("Dockerfile" "config.json" "nginx.conf" "entrypoint.sh" "index.html")
for f in "${REQUIRED[@]}"; do
    [[ ! -f "$f" ]] && { echo -e "${RED}❌ KULANG ANG FILE: $f${RESET}"; exit 1; }
done
python3 -m json.tool config.json >/dev/null 2>&1 || { echo -e "${RED}❌ MALI ANG config.json${RESET}"; exit 1; }
bash -n entrypoint.sh || { echo -e "${RED}❌ MALI ANG entrypoint.sh${RESET}"; exit 1; }
echo -e "${GREEN}Lahat ng files ay tama ✅${RESET}\n"

# --------------------------
# 6. BUILD AT I-UPLOAD SA CLOUD RUN
# --------------------------
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"
echo -e "${CYAN}Gumagawa ng server image...${RESET}"
gcloud builds submit --tag "$IMAGE" --quiet || { echo -e "${RED}❌ HINDI NAG-ANGAT ANG IMAGE${RESET}"; exit 1; }
echo -e "${GREEN}Image ready ✅${RESET}\n${CYAN}Inilalagay sa Cloud Run...${RESET}"

gcloud run deploy "$SERVICE_NAME" \
    --image "$IMAGE" \
    --platform managed \
    --region "$REGION" \
    --cpu "$CPU" --memory "$RAM" \
    --port 8080 --concurrency 800 --timeout 3600 \
    --min-instances 0 --max-instances "$MAX_INST" \
    --session-affinity \
    --allow-unauthenticated --quiet || { echo -e "${RED}❌ HINDI NAKA-DEPLOY${RESET}"; exit 1; }

# --------------------------
# 7. TAPOS NA!
# --------------------------
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" --format='value(status.url)')
echo -e "\n${GREEN}========================================${RESET}"
echo -e "${GREEN}✅ MATAGUMPAY ANG PAGLALAGAY!${RESET}"
echo -e "${CYAN}URI: ${BOLD}${DESC}${RESET}"
echo -e "${CYAN}SPEC: ${BOLD}${CPU}vCPU / ${RAM}${RESET}"
echo -e "${CYAN}LINK: ${BOLD}${SERVICE_URL}${RESET}"
echo -e "${GREEN}========================================${RESET}"

