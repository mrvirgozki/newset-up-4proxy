#!/bin/sh
set -eu

# ============================================================
# VIRGOZKI 4-PROXY + gRPC
# Envoy -> HAProxy -> OpenResty -> Apache -> Xray
# ============================================================

PORT="${PORT:-8080}"

HAPROXY_PORT="${HAPROXY_PORT:-8081}"
OPENRESTY_PORT="${OPENRESTY_PORT:-8082}"
APACHE_PORT="${APACHE_PORT:-8083}"

HAPROXY_GRPC_PORT="${HAPROXY_GRPC_PORT:-8084}"
OPENRESTY_GRPC_PORT="${OPENRESTY_GRPC_PORT:-8085}"

LOG_DIR="/tmp/virgozki-logs"


# ============================================================
# DIRECTORIES
# ============================================================

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


# ============================================================
# PIDS
# ============================================================

XRAY_PID=""
HAPROXY_PID=""
OPENRESTY_PID=""
APACHE_PID=""
ENVOY_PID=""

LAST_STEP="STARTING"


# ============================================================
# FUNCTIONS
# ============================================================

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

check_pid() {
    NAME="$1"
    PID="$2"

    if [ -z "$PID" ]; then
        echo "[virgozki] $NAME PID EMPTY"
        return 1
    fi

    if ! kill -0 "$PID" 2>/dev/null; then
        echo "[virgozki] $NAME STOPPED"
        return 1
    fi

    return 0
}

wait_for_port() {
    NAME="$1"
    HOST="$2"
    CHECK_PORT="$3"
    PID="$4"
    TIMEOUT="$5"

    END_TIME=$(( $(date +%s) + TIMEOUT ))

    while [ "$(date +%s)" -lt "$END_TIME" ]
    do
        # Check process first
        if ! check_pid "$NAME" "$PID"; then
            echo "[virgozki] $NAME died before port $CHECK_PORT became ready"
            return 1
        fi

        # Check TCP port
        if python3 - "$HOST" "$CHECK_PORT" <<'PY'
import socket
import sys
host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=1):
        sys.exit(0)
except Exception:
    sys.exit(1)
PY
        then
            log "$NAME port $CHECK_PORT READY"
            return 0
        fi

        sleep 1
    done

    echo "[virgozki] $NAME port $CHECK_PORT FAILED"
    return 1
}


# ============================================================
# EXIT HANDLER
# ============================================================

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
        echo " OpenResty : $OPENResty_PORT"
        echo " Apache    : $APACHE_PORT"
        echo " HAProxy gRPC   : $HAPROXY_GRPC_PORT"
        echo " OpenResty gRPC : $OPENRESTY_GRPC_PORT"
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

        echo "=============================================="
    fi

    trap - EXIT
    cleanup
    exit "$RC"
}

trap on_exit EXIT
trap 'exit 143' INT TERM


# ============================================================
# REQUIRED FILES
# ============================================================

step "Checking required files"

for FILE in \
    /etc/xray/config.json \
    /etc/openresty/nginx.conf \
    /etc/haproxy/haproxy.cfg \
    /etc/apache2/conf-available/virgozki.conf \
    /usr/share/nginx/html/index.html
do
    if [ ! -f "$FILE" ]; then
        echo "[virgozki] MISSING: $FILE"
        exit 1
    fi
done

log "All required files OK"


# ============================================================
# REQUIRED BINARIES
# ============================================================

step "Checking required binaries"

for CMD in \
    xray \
    openresty \
    envoy \
    haproxy \
    apache2ctl \
    python3
do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "[virgozki] REQUIRED BINARY NOT FOUND: $CMD"
        exit 1
    fi
done

log "All required binaries OK"


# ============================================================
# XRAY TEST
# ============================================================

step "Testing Xray configuration"

if ! xray run -test -c /etc/xray/config.json >"$LOG_DIR/xray-test.log" 2>&1; then
    echo "[virgozki] XRAY CONFIGURATION FAILED"
    cat "$LOG_DIR/xray-test.log"
    exit 1
fi

log "Xray configuration OK"


# ============================================================
# APACHE TEST
# ============================================================

step "Testing Apache configuration"

if ! apache2ctl -t >"$LOG_DIR/apache-test.log" 2>&1; then
    echo "[virgozki] APACHE CONFIGURATION FAILED"
    cat "$LOG_DIR/apache-test.log"
    exit 1
fi

log "Apache configuration OK"


# ============================================================
# OPENRESTY TEST
# ============================================================

step "Testing OpenResty configuration"

if ! openresty -t -c /etc/openresty/nginx.conf >"$LOG_DIR/openresty-test.log" 2>&1; then
    echo "[virgozki] OPENRESTY CONFIGURATION FAILED"
    cat "$LOG_DIR/openresty-test.log"
    exit 1
fi

log "OpenResty configuration OK"


# ============================================================
# HAPROXY TEST
# ============================================================

step "Testing HAProxy configuration"

if ! haproxy -c -f /etc/haproxy/haproxy.cfg >"$LOG_DIR/haproxy-test.log" 2>&1; then
    echo "[virgozki] HAPROXY CONFIGURATION FAILED"
    cat "$LOG_DIR/haproxy-test.log"
    exit 1
fi

log "HAProxy configuration OK"


# ============================================================
# CREATE ENVOY CONFIGURATION (FIXED: VARIABLES WORK NOW)
# ============================================================

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
          upgrade_configs:
          - upgrade_type: websocket
          request_headers_to_add:
          - header:
              key: X-Forwarded-Proto
              value: http
          route_config:
            name: public_routes
            virtual_hosts:
            - name: public
              domains:
              - "*"
              routes:
              - match:
                  prefix: "/openresty/"
                  grpc: {}
                route:
                  cluster: haproxy_grpc
                  timeout: 3600s
              - match:
                  prefix: "/"
                route:
                  cluster: haproxy_http
                  timeout: 3600s
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
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
                port_value: ${HAPROXY_GRPC_PORT}
YAML

log "Envoy config generated OK"


# ============================================================
# ENVOY TEST
# ============================================================

step "Testing Envoy configuration"

if ! envoy --mode validate -c /tmp/envoy-front.yaml >"$LOG_DIR/envoy-test.log" 2>&1; then
    echo "[virgozki] ENVOY CONFIGURATION FAILED"
    cat "$LOG_DIR/envoy-test.log"
    exit 1
fi

log "Envoy configuration OK"


# ============================================================
# START XRAY
# ============================================================

step "Starting Xray"

xray run -c /etc/xray/config.json >"$LOG_DIR/xray.log" 2>&1 &
XRAY_PID=$!

if ! wait_for_port "Xray" "127.0.0.1" 10000 "$XRAY_PID" 30; then
    echo "[virgozki] XRAY FAILED TO START"
    cat "$LOG_DIR/xray.log"
    exit 1
fi

log "Xray started"


# ============================================================
# START APACHE
# ============================================================

step "Starting Apache on 127.0.0.1:${APACHE_PORT}"

apache2ctl -D FOREGROUND >"$LOG_DIR/apache.log" 2>&1 &
APACHE_PID=$!

if ! check_pid "Apache" "$APACHE_PID"; then
    echo "[virgozki] APACHE FAILED TO START"
    cat "$LOG_DIR/apache.log"
    exit 1
fi

if ! wait_for_port "Apache" "127.0.0.1" "$APACHE_PORT" "$APACHE_PID" 30; then
    echo "[virgozki] APACHE PORT FAILED"
    cat "$LOG_DIR/apache.log"
    exit 1
fi

log "Apache started"


# ============================================================
# START OPENRESTY
# ============================================================

step "Starting OpenResty"

openresty -g "daemon off;" -c /etc/openresty/nginx.conf >"$LOG_DIR/openresty.log" 2>&1 &
OPENRESTY_PID=$!

if ! check_pid "OpenResty" "$OPENRESTY_PID"; then
    echo "[virgozki] OPENRESTY FAILED TO START"
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

if ! wait_for_port "OpenResty HTTP" "127.0.0.1" "$OPENRESTY_PORT" "$OPENRESTY_PID" 30; then
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

if ! wait_for_port "OpenResty gRPC" "127.0.0.1" "$OPENRESTY_GRPC_PORT" "$OPENRESTY_PID" 30; then
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

log "OpenResty started"


# ============================================================
# START HAPROXY
# ============================================================

step "Starting HAProxy"

haproxy -f /etc/haproxy/haproxy.cfg -db >"$LOG_DIR/haproxy.log" 2>&1 &
HAPROXY_PID=$!

if ! check_pid "HAProxy" "$HAPROXY_PID"; then
    echo "[virgozki] HAPROXY FAILED TO START"
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

if ! wait_for_port "HAProxy HTTP" "127.0.0.1" "$HAPROXY_PORT" "$HAPROXY_PID" 30; then
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

if ! wait_for_port "HAProxy gRPC" "127.0.0.1" "$HAPROXY_GRPC_PORT" "$HAPROXY_PID" 30; then
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

log "HAProxy started"


# ============================================================
# START ENVOY (MAIN ENTRY FOR CLOUD RUN)
# ============================================================

step "Starting Envoy on 0.0.0.0:${PORT}"

envoy -c /tmp/envoy-front.yaml --disable-hot-restart --log-level info >"$LOG_DIR/envoy.log" 2>&1 &
ENVOY_PID=$!

if ! check_pid "Envoy" "$ENVOY_PID"; then
    echo "[virgozki] ENVOY FAILED TO START"
    cat "$LOG_DIR/envoy.log"
    exit 1
fi


# ============================================================
# WAIT FOR PUBLIC PORT (FIXED CHECK)
# ============================================================

step "Waiting for public port ${PORT}"

if ! wait_for_port "Envoy PUBLIC" "localhost" "$PORT" "$ENVOY_PID" 60; then
    echo "[virgozki] ENVOY PUBLIC PORT FAILED"
    cat "$LOG_DIR/envoy.log"
    exit 1
fi

log "Envoy public port ${PORT} READY"


# ============================================================
# FINAL HEALTH CHECK
# ============================================================

step "Running final health checks"
check_pid "Envoy" "$ENVOY_PID"
check_pid "HAProxy" "$HAPROXY_PID"
check_pid "OpenResty" "$OPENRESTY_PID"
check_pid "Apache" "$APACHE_PID"
check_pid "Xray" "$XRAY_PID"


# ============================================================
# STARTUP COMPLETE
# ============================================================

echo ""
echo "=============================================="
echo " VIRGOZKI 4-PROXY STACK RUNNING"
echo "=============================================="
echo " Envoy          : 0.0.0.0:${PORT}"
echo " HAProxy        : 127.0.0.1:${HAPROXY_PORT}"
echo " OpenResty      : 127.0.0.1:${OPENRESTY_PORT}"
echo " Apache         : 127.0.0.1:${APACHE_PORT}"
echo " HAProxy gRPC   : 127.0.0.1:${HAPROXY_GRPC_PORT}"
echo " OpenResty gRPC : 127.0.0.1:${OPENRESTY_GRPC_PORT}"
echo " Xray           : 127.0.0.1:10000-10015"
echo "=============================================="
echo " CHAIN: Envoy -> HAProxy -> OpenResty -> Apache -> Xray"
echo "=============================================="
echo ""


# ============================================================
# KEEP CONTAINER RUNNING
# ============================================================

while true
do
    check_pid "Envoy" "$ENVOY_PID" || exit 1
    check_pid "HAProxy" "$HAPROXY_PID" || exit 1
    check_pid "OpenResty" "$OPENRESTY_PID" || exit 1
    check_pid "Apache" "$APACHE_PID" || exit 1
    check_pid "Xray" "$XRAY_PID" || exit 1
    sleep 5
done
