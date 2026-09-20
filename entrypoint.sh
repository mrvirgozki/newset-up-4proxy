#!/bin/sh
set -eu

PORT="${PORT:-8080}"
HAPROXY_PORT="${HAPROXY_PORT:-8081}"
OPENRESTY_PORT="${OPENRESTY_PORT:-8082}"
APACHE_PORT="${APACHE_PORT:-8083}"
GRPC_PORT="${GRPC_PORT:-8084}"

LOG_DIR="/tmp/virgozki-logs"

mkdir -p 
"$LOG_DIR" 
/tmp/virgozki 
/run/apache2 
/var/run/apache2 
/var/run/haproxy

chmod 777 
"$LOG_DIR" 
/tmp/virgozki 
/run/apache2 
/var/run/apache2 
/var/run/haproxy

XRAY_PID=""
HAPROXY_PID=""
OPENRESTY_PID=""
APACHE_PID=""
ENVOY_PID=""

LAST_STEP="STARTING"

log() {
echo "[virgozki] $*"
}

step() {
LAST_STEP="$1"
echo "[virgozki] STEP: $LAST_STEP"
}

show_log() {
NAME="$1"

echo ""
echo "----- $NAME -----"

if [ -f "$LOG_DIR/$NAME.log" ]; then
    cat "$LOG_DIR/$NAME.log"
else
    echo "NO LOG FILE"
fi

}

cleanup() {
echo "[virgozki] Stopping services..."

for PID in \
    "${ENVOY_PID:-}" \
    "${HAPROXY_PID:-}" \
    "${OPENRESTY_PID:-}" \
    "${APACHE_PID:-}" \
    "${XRAY_PID:-}"
do
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
    fi
done

}

on_exit() {
RC=$?

if [ "$RC" -ne 0 ]; then
    echo ""
    echo "=============================================="
    echo " VIRGOZKI STARTUP FAILED"
    echo " EXIT CODE : $RC"
    echo " LAST STEP : $LAST_STEP"
    echo " PUBLIC    : $PORT"
    echo " HAProxy   : $HAPROXY_PORT"
    echo " OpenResty : $OPENRESTY_PORT"
    echo " Apache    : $APACHE_PORT"
    echo " gRPC      : $GRPC_PORT"
    echo "=============================================="

    show_log envoy-test
    show_log envoy
    show_log haproxy-test
    show_log haproxy
    show_log openresty-test
    show_log openresty
    show_log apache-test
    show_log apache
    show_log xray-test
    show_log xray
fi

cleanup
exit "$RC"

}

trap on_exit EXIT
trap 'exit 143' INT TERM

==================================================

REQUIRED FILES

==================================================

step "Checking required files"

for FILE in 
/etc/xray/config.json 
/etc/openresty/nginx.conf 
/etc/haproxy/haproxy.cfg 
/etc/apache2/conf-available/virgozki.conf 
/usr/share/nginx/html/index.html
do
if [ ! -f "$FILE" ]; then
echo "[virgozki] MISSING: $FILE"
exit 1
fi
done

log "All required files OK"

==================================================

REQUIRED BINARIES

==================================================

step "Checking required binaries"

for CMD in 
xray 
openresty 
envoy 
haproxy 
apache2ctl
do
if ! command -v "$CMD" >/dev/null 2>&1; then
echo "[virgozki] REQUIRED BINARY NOT FOUND: $CMD"
exit 1
fi
done

log "All required binaries OK"

==================================================

XRAY TEST

==================================================

step "Testing Xray configuration"

xray test 
-c /etc/xray/config.json 
>"$LOG_DIR/xray-test.log" 2>&1 || {
echo "[virgozki] XRAY CONFIGURATION FAILED"
cat "$LOG_DIR/xray-test.log"
exit 1
}

log "Xray configuration OK"

==================================================

APACHE TEST

==================================================

step "Testing Apache configuration"

apache2ctl -t 
>"$LOG_DIR/apache-test.log" 2>&1 || {
echo "[virgozki] APACHE CONFIGURATION FAILED"
cat "$LOG_DIR/apache-test.log"
exit 1
}

log "Apache configuration OK"

==================================================

OPENRESTY TEST

==================================================

step "Testing OpenResty configuration"

openresty -t 
-c /etc/openresty/nginx.conf 
>"$LOG_DIR/openresty-test.log" 2>&1 || {
echo "[virgozki] OPENRESTY CONFIGURATION FAILED"
cat "$LOG_DIR/openresty-test.log"
exit 1
}

log "OpenResty configuration OK"

==================================================

HAPROXY TEST

==================================================

step "Testing HAProxy configuration"

haproxy 
-c 
-f /etc/haproxy/haproxy.cfg 
>"$LOG_DIR/haproxy-test.log" 2>&1 || {
echo "[virgozki] HAPROXY CONFIGURATION FAILED"
cat "$LOG_DIR/haproxy-test.log"
exit 1
}

log "HAProxy configuration OK"

==================================================

ENVOY CONFIG

==================================================

step "Creating Envoy configuration"

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
      
      stream_idle_timeout: 3600s
      
      normalize_path: true
      
      route_config:
      
      name: public_routes

virtual_hosts:

- name: public

  domains:
  - "*"

  routes:

  # gRPC -> HAProxy TCP gRPC listener
  - match:
      prefix: "/openresty/"
      grpc: {}
    route:
      cluster: haproxy_grpc
      timeout: 3600s
      upgrade_configs:
      - upgrade_type: websocket

  # Everything else -> HAProxy HTTP listener
  - match:
      prefix: "/"
    route:
      cluster: haproxy_http
      timeout: 3600s
      upgrade_configs:
      - upgrade_type: websocket
      
      http_filters:
      
      - name: envoy.filters.http.router
        
        typed_config:
        "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

clusters:

=========================================================

HTTP / WS / XHTTP

=========================================================

- name: haproxy_http
  
  connect_timeout: 10s
  
  type: STATIC
  
  lb_policy: ROUND_ROBIN
  
  load_assignment:
  
  cluster_name: haproxy_http
  
  endpoints:
  
  - lb_endpoints:
    
    - endpoint:
      
      address:
      
      socket_address:
  address: 127.0.0.1
  port_value: ${HAPROXY_PORT}

=========================================================

gRPC HTTP/2

=========================================================

- name: haproxy_grpc
  
  connect_timeout: 10s
  
  type: STATIC
  
  lb_policy: ROUND_ROBIN
  
  http2_protocol_options: {}
  
  load_assignment:
  
  cluster_name: haproxy_grpc
  
  endpoints:
  
  - lb_endpoints:
    
    - endpoint:
      
      address:
      
      socket_address:
  address: 127.0.0.1
  port_value: ${GRPC_PORT}

YAML

==================================================

ENVOY TEST

==================================================

step "Testing Envoy configuration"

envoy 
--mode validate 
-c /tmp/envoy-front.yaml 
>"$LOG_DIR/envoy-test.log" 2>&1 || {
echo "[virgozki] ENVOY CONFIGURATION FAILED"
cat "$LOG_DIR/envoy-test.log"
exit 1
}

log "Envoy configuration OK"

==================================================

START XRAY

==================================================

step "Starting Xray"

xray run 
-c /etc/xray/config.json 
>"$LOG_DIR/xray.log" 2>&1 &

XRAY_PID=$!

sleep 2

kill -0 "$XRAY_PID" 2>/dev/null || {
echo "[virgozki] XRAY FAILED TO START"
cat "$LOG_DIR/xray.log"
exit 1
}

log "Xray started"

==================================================

START APACHE

==================================================

step "Starting Apache on 127.0.0.1:${APACHE_PORT}"

apache2ctl 
-D FOREGROUND 
>"$LOG_DIR/apache.log" 2>&1 &

APACHE_PID=$!

sleep 2

kill -0 "$APACHE_PID" 2>/dev/null || {
echo "[virgozki] APACHE FAILED TO START"
cat "$LOG_DIR/apache.log"
exit 1
}

log "Apache started"

==================================================

START OPENRESTY

==================================================

step "Starting OpenResty HTTP:${OPENRESTY_PORT} gRPC:${GRPC_PORT}"

openresty 
-g "daemon off;" 
-c /etc/openresty/nginx.conf 
>"$LOG_DIR/openresty.log" 2>&1 &

OPENRESTY_PID=$!

sleep 2

kill -0 "$OPENRESTY_PID" 2>/dev/null || {
echo "[virgozki] OPENRESTY FAILED TO START"
cat "$LOG_DIR/openresty.log"
exit 1
}

log "OpenResty started"

==================================================

START HAPROXY

==================================================

step "Starting HAProxy"

haproxy 
-f /etc/haproxy/haproxy.cfg 
-db 
>"$LOG_DIR/haproxy.log" 2>&1 &

HAPROXY_PID=$!

sleep 2

kill -0 "$HAPROXY_PID" 2>/dev/null || {
echo "[virgozki] HAPROXY FAILED TO START"
cat "$LOG_DIR/haproxy.log"
exit 1
}

log "HAProxy started"

==================================================

START ENVOY

==================================================

step "Starting Envoy on 0.0.0.0:${PORT}"

envoy 
-c /tmp/envoy-front.yaml 
--disable-hot-restart 
--log-level info 
>"$LOG_DIR/envoy.log" 2>&1 &

ENVOY_PID=$!

==================================================

WAIT FOR PUBLIC PORT

==================================================

step "Waiting for public port ${PORT}"

python3 - "$PORT" "$ENVOY_PID" <<'PY'
import socket
import sys
import time
import os

port = int(sys.argv[1])
pid = int(sys.argv[2])

deadline = time.time() + 30

while time.time() < deadline:
try:
with socket.create_connection(
("127.0.0.1", port),
timeout=1
):
print(f"[virgozki] PORT {port} READY")
sys.exit(0)
except Exception:
pass

try:
    os.kill(pid, 0)
except OSError:
    print("[virgozki] Envoy stopped")
    sys.exit(1)

time.sleep(1)

print(f"[virgozki] PORT {port} FAILED")
sys.exit(1)
PY

==================================================

FINAL CHECK

==================================================

step "Running final health checks"

for NAME PID in 
envoy "$ENVOY_PID" 
haproxy "$HAPROXY_PID" 
openresty "$OPENRESTY_PID" 
apache "$APACHE_PID" 
xray "$XRAY_PID"
do
if ! kill -0 "$PID" 2>/dev/null; then
echo "[virgozki] $NAME STOPPED"
exit 1
fi
done

echo ""
echo "=============================================="
echo " VIRGOZKI 4-PROXY STACK RUNNING"
echo "=============================================="
echo " Envoy     : 0.0.0.0:${PORT}"
echo " HAProxy   : 127.0.0.1:${HAPROXY_PORT}"
echo " OpenResty : 127.0.0.1:${OPENRESTY_PORT}"
echo " Apache    : 127.0.0.1:${APACHE_PORT}"
echo " gRPC      : 127.0.0.1:${GRPC_PORT}"
echo " Xray      : 127.0.0.1:10000-10015"
echo "=============================================="
echo " CHAIN"
echo " Envoy -> HAProxy -> OpenResty -> Apache -> Xray"
echo "=============================================="
echo ""

while true; do

for NAME PID in \
    envoy "$ENVOY_PID" \
    haproxy "$HAPROXY_PID" \
    openresty "$OPENRESTY_PID" \
    apache "$APACHE_PID" \
    xray "$XRAY_PID"
do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "[virgozki] $NAME STOPPED"
        exit 1
    fi
done

sleep 5

done
