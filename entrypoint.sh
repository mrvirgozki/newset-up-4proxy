#!/bin/sh
set -eu

# ==================================================
# PORTS
# ==================================================

PORT="${PORT:-8080}"
HAPROXY_PORT="${HAPROXY_PORT:-8081}"
OPENRESTY_PORT="${OPENRESTY_PORT:-8082}"
APACHE_PORT="${APACHE_PORT:-8083}"

LOG_DIR="/tmp/virgozki-logs"

# ==================================================
# DIRECTORIES
# ==================================================

mkdir -p \
    "$LOG_DIR" \
    /tmp/virgozki \
    /run/apache2 \
    /var/run/apache2 \
    /var/run/haproxy

chmod 777 \
    "$LOG_DIR" \
    /tmp/virgozki \
    /run/apache2 \
    /var/run/apache2 \
    /var/run/haproxy

# ==================================================
# PIDS
# ==================================================

XRAY_PID=""
HAPROXY_PID=""
OPENRESTY_PID=""
APACHE_PID=""
ENVOY_PID=""

LAST_STEP="STARTING"

# ==================================================
# LOGGING
# ==================================================

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

# ==================================================
# CLEANUP
# ==================================================

cleanup() {
    echo "[virgozki] Stopping services..."

    if [ -n "${ENVOY_PID:-}" ]; then
        kill "$ENVOY_PID" 2>/dev/null || true
    fi

    if [ -n "${HAPROXY_PID:-}" ]; then
        kill "$HAPROXY_PID" 2>/dev/null || true
    fi

    if [ -n "${OPENRESTY_PID:-}" ]; then
        kill "$OPENRESTY_PID" 2>/dev/null || true
    fi

    if [ -n "${APACHE_PID:-}" ]; then
        kill "$APACHE_PID" 2>/dev/null || true
    fi

    if [ -n "${XRAY_PID:-}" ]; then
        kill "$XRAY_PID" 2>/dev/null || true
    fi
}

# ==================================================
# EXIT HANDLER
# ==================================================

on_exit() {
    RC=$?

    if [ "$RC" -ne 0 ]; then

        echo ""
        echo "=============================================="
        echo " VIRGOZKI STARTUP FAILED"
        echo " EXIT CODE   : $RC"
        echo " LAST STEP   : $LAST_STEP"
        echo " PUBLIC      : $PORT"
        echo " HAPROXY     : $HAPROXY_PORT"
        echo " OPENRESTY   : $OPENRESTY_PORT"
        echo " APACHE      : $APACHE_PORT"
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

        echo ""
        echo "=============================================="
    fi

    cleanup
    exit "$RC"
}

trap on_exit EXIT
trap 'exit 143' INT TERM

# ==================================================
# CHECK REQUIRED FILES
# ==================================================

step "Checking required files"

for FILE in \
    /etc/xray/config.json \
    /etc/openresty/nginx.conf \
    /etc/haproxy/haproxy.cfg \
    /etc/apache2/httpd.conf \
    /usr/share/nginx/html/index.html
do

    if [ ! -f "$FILE" ]; then
        echo "[virgozki] MISSING: $FILE"
        exit 1
    fi

done

log "All required files OK"

# ==================================================
# CHECK REQUIRED BINARIES
# ==================================================

step "Checking required binaries"

for CMD in \
    xray \
    openresty \
    envoy \
    haproxy \
    httpd
do

    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "[virgozki] REQUIRED BINARY NOT FOUND: $CMD"
        exit 1
    fi

done

log "All required binaries OK"

# ==================================================
# TEST XRAY
# ==================================================

step "Testing Xray configuration"

xray test \
    -c /etc/xray/config.json \
    >"$LOG_DIR/xray-test.log" 2>&1 || {

    echo "[virgozki] XRAY CONFIGURATION FAILED"
    cat "$LOG_DIR/xray-test.log"
    exit 1
}

log "Xray configuration OK"

# ==================================================
# TEST OPENRESTY
# ==================================================

step "Testing OpenResty configuration"

openresty -t \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty-test.log" 2>&1 || {

    echo "[virgozki] OPENRESTY CONFIGURATION FAILED"
    cat "$LOG_DIR/openresty-test.log"
    exit 1
}

log "OpenResty configuration OK"

# ==================================================
# TEST HAPROXY
# ==================================================

step "Testing HAProxy configuration"

haproxy \
    -c \
    -f /etc/haproxy/haproxy.cfg \
    >"$LOG_DIR/haproxy-test.log" 2>&1 || {

    echo "[virgozki] HAPROXY CONFIGURATION FAILED"
    cat "$LOG_DIR/haproxy-test.log"
    exit 1
}

log "HAProxy configuration OK"

# ==================================================
# TEST APACHE
# ==================================================

step "Testing Apache configuration"

httpd \
    -t \
    -f /etc/apache2/httpd.conf \
    >"$LOG_DIR/apache-test.log" 2>&1 || {

    echo "[virgozki] APACHE CONFIGURATION FAILED"
    cat "$LOG_DIR/apache-test.log"
    exit 1
}

log "Apache configuration OK"

# ==================================================
# CREATE ENVOY CONFIG
# ==================================================

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

          normalize_path: true

          route_config:

            name: public_routes

            virtual_hosts:

            - name: public

              domains:
              - "*"

              routes:

              - match:
                  prefix: "/"
                route:
                  cluster: haproxy
                  timeout: 3600s

          http_filters:

          - name: envoy.filters.http.router

            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router


  clusters:

  - name: haproxy

    connect_timeout: 10s

    type: STATIC

    lb_policy: ROUND_ROBIN

    load_assignment:

      cluster_name: haproxy

      endpoints:

      - lb_endpoints:

        - endpoint:

            address:

              socket_address:
                address: 127.0.0.1
                port_value: ${HAPROXY_PORT}

YAML

# ==================================================
# TEST ENVOY
# ==================================================

step "Testing Envoy configuration"

envoy \
    --mode validate \
    -c /tmp/envoy-front.yaml \
    >"$LOG_DIR/envoy-test.log" 2>&1 || {

    echo "[virgozki] ENVOY CONFIGURATION FAILED"
    cat "$LOG_DIR/envoy-test.log"
    exit 1
}

log "Envoy configuration OK"

# ==================================================
# START XRAY
# ==================================================

step "Starting Xray"

xray run \
    -c /etc/xray/config.json \
    >"$LOG_DIR/xray.log" 2>&1 &

XRAY_PID=$!

sleep 2

if ! kill -0 "$XRAY_PID" 2>/dev/null; then

    echo "[virgozki] XRAY FAILED TO START"
    cat "$LOG_DIR/xray.log"

    exit 1
fi

log "Xray started"

# ==================================================
# START APACHE
# ==================================================

step "Starting Apache on 127.0.0.1:${APACHE_PORT}"

httpd \
    -D FOREGROUND \
    -f /etc/apache2/httpd.conf \
    >"$LOG_DIR/apache.log" 2>&1 &

APACHE_PID=$!

sleep 2

if ! kill -0 "$APACHE_PID" 2>/dev/null; then

    echo "[virgozki] APACHE FAILED TO START"
    cat "$LOG_DIR/apache.log"

    exit 1
fi

log "Apache started"

# ==================================================
# START OPENRESTY
# ==================================================

step "Starting OpenResty on 127.0.0.1:${OPENRESTY_PORT}"

openresty \
    -g "daemon off;" \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty.log" 2>&1 &

OPENRESTY_PID=$!

sleep 2

if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then

    echo "[virgozki] OPENRESTY FAILED TO START"
    cat "$LOG_DIR/openresty.log"

    exit 1
fi

log "OpenResty started"

# ==================================================
# START HAPROXY
# ==================================================

step "Starting HAProxy on 127.0.0.1:${HAPROXY_PORT}"

haproxy \
    -f /etc/haproxy/haproxy.cfg \
    -db \
    >"$LOG_DIR/haproxy.log" 2>&1 &

HAPROXY_PID=$!

sleep 2

if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then

    echo "[virgozki] HAPROXY FAILED TO START"
    cat "$LOG_DIR/haproxy.log"

    exit 1
fi

log "HAProxy started"

# ==================================================
# START ENVOY
# ==================================================

step "Starting Envoy on 0.0.0.0:${PORT}"

envoy \
    -c /tmp/envoy-front.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy.log" 2>&1 &

ENVOY_PID=$!

# ==================================================
# WAIT FOR ENVOY
# ==================================================

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

# ==================================================
# FINAL HEALTH CHECK
# ==================================================

step "Running final health checks"

sleep 2

if ! kill -0 "$ENVOY_PID" 2>/dev/null; then
    echo "[virgozki] ENVOY STOPPED"
    cat "$LOG_DIR/envoy.log"
    exit 1
fi

if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
    echo "[virgozki] HAPROXY STOPPED"
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
    echo "[virgozki] OPENRESTY STOPPED"
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

if ! kill -0 "$APACHE_PID" 2>/dev/null; then
    echo "[virgozki] APACHE STOPPED"
    cat "$LOG_DIR/apache.log"
    exit 1
fi

if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    echo "[virgozki] XRAY STOPPED"
    cat "$LOG_DIR/xray.log"
    exit 1
fi

# ==================================================
# DEPLOYED
# ==================================================

step "VIRGOZKI 4-PROXY STACK RUNNING"

echo ""
echo "=============================================="
echo " VIRGOZKI DEPLOYED"
echo "=============================================="
echo " Envoy     : 0.0.0.0:${PORT}"
echo " HAProxy   : 127.0.0.1:${HAPROXY_PORT}"
echo " OpenResty : 127.0.0.1:${OPENRESTY_PORT}"
echo " Apache    : 127.0.0.1:${APACHE_PORT}"
echo " Xray      : 127.0.0.1:10000-10015"
echo "=============================================="
echo ""
echo "CHAIN:"
echo "Envoy -> HAProxy -> OpenResty -> Apache -> Xray"
echo ""

# ==================================================
# MONITORING
# ==================================================

while true; do

    if ! kill -0 "$ENVOY_PID" 2>/dev/null; then
        echo "[virgozki] ENVOY STOPPED"
        exit 1
    fi

    if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
        echo "[virgozki] HAPROXY STOPPED"
        exit 1
    fi

    if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
        echo "[virgozki] OPENRESTY STOPPED"
        exit 1
    fi

    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "[virgozki] APACHE STOPPED"
        exit 1
    fi

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[virgozki] XRAY STOPPED"
        exit 1
    fi

    sleep 5

done
