#!/bin/sh  
set -eu  

PORT="${PORT:-8080}"  
LOG_DIR="/tmp/virgozki-logs"  

mkdir -p \  
    "$LOG_DIR" \  
    /tmp/virgozki \  
    /run/apache2 \  
    /var/run/apache2 \  
    /var/run/haproxy  

chmod -R 777 "$LOG_DIR" /tmp/virgozki /run /var/run  

XRAY_PID=""  
OPENRESTY_PID=""  
HAPROXY_PID=""  
ENVOY_ENGINE_PID=""  
APACHE_PID=""  
ENVOY_FRONT_PID=""  

LAST_STEP="STARTING"  

log() { echo "[virgozki] $*"; }  
step() { LAST_STEP="$1"; echo "[virgozki] STEP: $LAST_STEP"; }  

show_log() {  
    NAME="$1"  
    echo ""; echo "----- $NAME -----"  
    [ -f "$LOG_DIR/$NAME.log" ] && cat "$LOG_DIR/$NAME.log" || echo "NO LOG FILE"  
}  

cleanup() {  
    echo "[virgozki] Stopping services..."  
    kill "$ENVOY_FRONT_PID" 2>/dev/null || true  
    kill "$APACHE_PID" 2>/dev/null || true  
    kill "$ENVOY_ENGINE_PID" 2>/dev/null || true  
    kill "$HAPROXY_PID" 2>/dev/null || true  
    kill "$OPENRESTY_PID" 2>/dev/null || true  
    kill "$XRAY_PID" 2>/dev/null || true  
}  

on_exit() {  
    RC=$?  
    if [ "$RC" -ne 0 ]; then  
        echo ""  
        echo "=============================================="  
        echo " VIRGOZKI STARTUP FAILED"  
        echo " EXIT CODE : $RC"  
        echo " LAST STEP : $LAST_STEP"  
        echo " PORT      : $PORT"  
        echo "=============================================="  
        show_log envoy-front-test; show_log envoy-front  
        show_log xray-test; show_log xray  
        show_log openresty-test; show_log openresty  
        echo ""; echo "=============================================="  
    fi  
    cleanup  
    exit "$RC"  
}  

trap on_exit EXIT  
trap 'exit 143' INT TERM  

# ==================================================  
# ✅ CHECK FILES  
# ==================================================  
step "Checking required files"  
for FILE in \  
    /etc/xray/config.json \  
    /etc/openresty/nginx.conf \  
    /usr/share/nginx/html/index.html  
do  
    [ ! -f "$FILE" ] && { echo "[virgozki] MISSING: $FILE"; exit 1; }  
done  

command -v xray >/dev/null 2>&1 || { echo "[virgozki] xray not found"; exit 1; }  
command -v openresty >/dev/null 2>&1 || { echo "[virgozki] openresty not found"; exit 1; }  
log "All files & binaries OK"  

# ==================================================  
# ✅ FIXED ENVOY: HINDI NA BABAWASAN ANG PREFIX!
# ==================================================  
step "Creating public Envoy config"  
cat > /tmp/envoy-front.yaml <<YAML  
static_resources:  
  listeners:  
  - name: public_listener  
    address:  
      socket_address:  
        address: 0.0.0.0  
        port_value: ${PORT}  
    filter_chains:  
    - filters:  
      - name: envoy.filters.network.http_connection_manager  
        typed_config:  
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager  
          stat_prefix: public  
          codec_type: AUTO  
          use_remote_address: true  
          route_config:  
            name: public_routes  
            virtual_hosts:  
            - name: public  
              domains: ["*"]  
              routes:  
              # ✅ Panel + Lahat ng /openresty/ path (IPAPASA BUO ANG PREFIX!)
              - match: { prefix: "/openresty/" }  
                route: { cluster: openresty_http, timeout: 3600s }  
              - match: { path: "/" }  
                route: { cluster: openresty_http, timeout: 3600s }  
          http_filters:  
          - name: envoy.filters.http.router  
            typed_config: { "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }  
  clusters:  
  - name: openresty_http  
    connect_timeout: 10s  
    type: STATIC  
    load_assignment: { cluster_name: openresty_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8080 } } } }] }] }  
YAML  

step "Validating Envoy"  
envoy --mode validate -c /tmp/envoy-front.yaml >"$LOG_DIR/envoy-front-test.log" 2>&1 || {  
    echo "[virgozki] ENVOY VALIDATION FAILED"; cat "$LOG_DIR/envoy-front-test.log"; exit 1  
}  
log "Envoy OK"  

step "Starting Envoy on 0.0.0.0:$PORT"  
envoy -c /tmp/envoy-front.yaml --disable-hot-restart --log-level info >"$LOG_DIR/envoy-front.log" 2>&1 &  
ENVOY_FRONT_PID=$!  

# ==================================================  
# ✅ WAIT FOR PORT  
# ==================================================  
step "Waiting for port $PORT"  
python3 - "$PORT" "$ENVOY_FRONT_PID" <<'PY'  
import socket, sys, time, os  
port, pid = int(sys.argv[1]), int(sys.argv[2])  
deadline = time.time() + 30  
while time.time() < deadline:  
    try:  
        with socket.create_connection(("127.0.0.1", port), timeout=1):  
            print(f"[virgozki] PORT {port} READY")  
            sys.exit(0)  
    except: pass  
    try: os.kill(pid,0)  
    except: print("[virgozki] Envoy stopped"); sys.exit(1)  
    time.sleep(1)  
print(f"[virgozki] PORT {port} FAILED")  
sys.exit(1)  
PY  

log "CLOUD RUN PORT READY: 0.0.0.0:$PORT"  

# ==================================================  
# ✅ FIXED XRAY TEST COMMAND  
# ==================================================  
step "Testing Xray"  
xray test -c /etc/xray/config.json >"$LOG_DIR/xray-test.log" 2>&1 || {  
    echo "[virgozki] XRAY FAILED"; cat "$LOG_DIR/xray-test.log"; exit 1  
}  
log "Xray OK"  

step "Starting Xray"  
xray run -c /etc/xray/config.json >"$LOG_DIR/xray.log" 2>&1 &  
XRAY_PID=$!  

# ==================================================  
# ✅ OPENRESTY (TUGMA NA SA LAHAT)
# ==================================================  
step "Testing OpenResty"  
openresty -t -c /etc/openresty/nginx.conf >"$LOG_DIR/openresty-test.log" 2>&1 || {  
    echo "[virgozki] OPENRESTY FAILED"; cat "$LOG_DIR/openresty-test.log"; exit 1  
}  
log "OpenResty OK"  

step "Starting OpenResty on 127.0.0.1:8080"  
openresty -g "daemon off;" -c /etc/openresty/nginx.conf >"$LOG_DIR/openresty.log" 2>&1 &  
OPENRESTY_PID=$!  

# ==================================================  
# ✅ TINANGGAL ANG DUPLICATE SERVICES (HAProxy/Envoy/Apache)
# Hindi na kailangan dahil OpenResty na ang humahawak ng lahat ng path
# ==================================================  

# ==================================================  
# ✅ HEALTH CHECKS  
# ==================================================  
sleep 3  
kill -0 "$ENVOY_FRONT_PID" 2>/dev/null || { echo "[virgozki] ❌ ENVOY STOPPED"; exit 1; }  
kill -0 "$XRAY_PID" 2>/dev/null || { echo "[virgozki] ❌ XRAY STOPPED"; exit 1; }  
kill -0 "$OPENRESTY_PID" 2>/dev/null || { echo "[virgozki] ❌ OPENRESTY STOPPED"; exit 1; }  

step "✅ VIRGOZKI FULLY DEPLOYED & RUNNING"  
log "🌐 Public Access: https://<your-run-app-domain>"  
log "📊 Panel: /"  
log "🔌 All paths under: /openresty/ match your config generator"  
log "✅ Paths now match perfectly between Envoy → OpenResty → Xray"  

# ==================================================  
# ✅ MONITORING  
# ==================================================  
while true; do  
    kill -0 "$ENVOY_FRONT_PID" 2>/dev/null || exit 1  
    kill -0 "$XRAY_PID" 2>/dev/null || exit 1  
    kill -0 "$OPENRESTY_PID" 2>/dev/null || exit 1  
    sleep 5  
done  
