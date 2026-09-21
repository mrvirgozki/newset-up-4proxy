#!/bin/bash
set -euo pipefail

# ==============================================
# ENV VARS — TUGMA SA DOCKERFILE AT CLOUD RUN
# ==============================================
PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

HAPROXY_PORT="${HAPROXY_PORT:-8081}"
OPENRESTY_PORT="${OPENRESTY_PORT:-8082}"
APACHE_PORT="${APACHE_PORT:-8083}"

HAPROXY_GRPC_PORT="${HAPROXY_GRPC_PORT:-8084}"
OPENRESTY_GRPC_PORT="${OPENRESTY_GRPC_PORT:-8085}"

XRAY_CONFIG="/etc/xray/config.json"
NGINX_CONFIG="/etc/openresty/nginx.conf"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
ENVOY_CONFIG="/etc/envoy/envoy.yaml"

PIDS=()

# ==============================================
# CLEANUP FUNCTION
# ==============================================
cleanup() {
    echo "[entrypoint] 🛑 Shutting down services..."
    for pid in "${PIDS[@]:-}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 3
    for pid in "${PIDS[@]:-}"; do
        kill -KILL "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

# ==============================================
# BANNER & PREPARE
# ==============================================
echo "======================================"
echo " 🚀 Virgozki Proxy Stack Starting"
echo "======================================"

mkdir -p \
/tmp/virgozki-logs \
/tmp/virgozki \
/etc/envoy \
/run/haproxy \
/var/run/apache2 \
/var/log/apache2 \
/var/log/xray

# ==============================================
# ✅ CHECK BINARIES
# ==============================================
echo "[check] 🔍 Verifying binaries..."
command -v xray >/dev/null || { echo "❌ Missing: xray"; exit 1; }
command -v openresty >/dev/null || { echo "❌ Missing: openresty"; exit 1; }
command -v haproxy >/dev/null || { echo "❌ Missing: haproxy"; exit 1; }
command -v apache2ctl >/dev/null || { echo "❌ Missing: apache2ctl"; exit 1; }
command -v envoy >/dev/null || { echo "❌ Missing: envoy"; exit 1; }
command -v python3 >/dev/null || { echo "❌ Missing: python3"; exit 1; }

# ==============================================
# CHECK CONFIG FILES
# ==============================================
echo "[check] 📄 Verifying config files..."
for f in "$XRAY_CONFIG" "$NGINX_CONFIG" "$HAPROXY_CONFIG"; do
    [ -f "$f" ] || { echo "❌ Missing file: $f"; exit 1; }
done

# ==============================================
# ✅ AYOS NA SED — TUGMA SA BAGONG NGINX FORMAT
# ==============================================
echo "[config] 🔧 Updating OpenResty ports to local only..."
# Palitan ang lahat ng listen address papuntang 127.0.0.1, iwas conflict sa Envoy
sed -i -E "s/^(\s*)listen\s+[0-9.]+:8080;/\1listen 127.0.0.1:${OPENRESTY_PORT};/" "$NGINX_CONFIG"
sed -i -E "s/^(\s*)listen\s+[0-9.]+:8085;/\1listen 127.0.0.1:${OPENRESTY_GRPC_PORT};/" "$NGINX_CONFIG"

# ==============================================
# VALIDATE ALL CONFIGS
# ==============================================
echo "[test] ✅ Testing Xray config..."
xray -test -config "$XRAY_CONFIG"

echo "[test] ✅ Testing OpenResty config..."
openresty -t -c "$NGINX_CONFIG"

echo "[test] ✅ Testing HAProxy config..."
haproxy -c -f "$HAPROXY_CONFIG"

# ==============================================
# START SERVICES (TAMANG PAGKAKASUNOD)
# ==============================================
echo "[start] 📡 Starting Xray..."
xray run -config "$XRAY_CONFIG" > /tmp/virgozki-logs/xray.log 2>&1 &
PIDS+=($!)
sleep 3

echo "[start] 🌐 Starting Apache backend..."
apache2ctl -DFOREGROUND > /tmp/virgozki-logs/apache.log 2>&1 &
PIDS+=($!)
sleep 2

echo "[start] 🛡️ Starting Anti-DDoS..."
python3 /usr/local/bin/anti_ddos.py > /tmp/virgozki-logs/anti_ddos.log 2>&1 &
PIDS+=($!)
sleep 2

echo "[start] 🔄 Starting OpenResty (local only)..."
openresty -c "$NGINX_CONFIG" -g "daemon off;" > /tmp/virgozki-logs/openresty.log 2>&1 &
PIDS+=($!)
sleep 2

echo "[start] ⚖️ Starting HAProxy..."
haproxy -db -f "$HAPROXY_CONFIG" > /tmp/virgozki-logs/haproxy.log 2>&1 &
PIDS+=($!)
sleep 3  # ✅ Pahabain ng kaunti para siguradong handa

# ==============================================
# ✅ AUTO-GENERATE ENVOY CONFIG (PUBLIC PORT 8080)
# ==============================================
echo "[config] 🚪 Generating Envoy config for $BIND_ADDR:$PORT..."
cat > "$ENVOY_CONFIG" <<EOF
static_resources:
  listeners:
  - name: public_listener
    address:
      socket_address:
        address: ${BIND_ADDR}
        port_value: ${PORT}
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: proxy
          codec_type: AUTO
          route_config:
            name: local
            virtual_hosts:
            - name: backend
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route:
                  cluster: haproxy_http
                  timeout: 3600s
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: haproxy_http
    connect_timeout: 5s
    type: STATIC
    load_assignment:
      cluster_name: haproxy_http
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: ${HAPROXY_PORT}
admin:
  access_log_path: /tmp/envoy-admin.log
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901
EOF

echo "[test] ✅ Testing Envoy config..."
envoy --mode validate -c "$ENVOY_CONFIG"

echo "[start] 🌐 Starting Envoy — listening on PUBLIC $BIND_ADDR:$PORT..."
envoy -c "$ENVOY_CONFIG" --log-level warning > /tmp/virgozki-logs/envoy.log 2>&1 &
PIDS+=($!)

# ✅ MAHALAGA: Pahabain bago ipakita na running — para hindi ma-timeout ang Cloud Run
sleep 10

# ==============================================
# FINAL STATUS — IPAPAKITA LANG PAG SIGURADONG LISTENING NA
# ==============================================
echo "======================================"
echo " ✅ ALL SERVICES RUNNING — LISTENING ON $PORT"
echo "======================================"
echo "🌐 Public Access : $BIND_ADDR:$PORT"
echo "⚖️ HAProxy       : 127.0.0.1:$HAPROXY_PORT"
echo "🔄 OpenResty     : 127.0.0.1:$OPENRESTY_PORT / $OPENRESTY_GRPC_PORT"
echo "🌐 Panel Ready    : / index.html"
echo "🛡️ Anti-DDoS     : Active"
echo "======================================"

# ==============================================
# HEALTH CHECK LOOP
# ==============================================
while true; do
    for pid in "${PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo -e "\n❌ CRITICAL: Process stopped!"
            echo -e "\n📋 Recent logs:"
            tail -n 15 /tmp/virgozki-logs/*.log 2>/dev/null || true
            exit 1
        fi
    done
    sleep 5
done
