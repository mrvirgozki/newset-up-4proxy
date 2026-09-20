#!/bin/sh
set -eu

# ============================================================
# VIRGOZKI 4-PROXY + gRPC
# CLOUD RUN
#
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
# PID VARIABLES
# ============================================================

XRAY_PID=""
APACHE_PID=""
OPENRESTY_PID=""
HAPROXY_PID=""
ENVOY_PID=""

LAST_STEP="STARTING"

# ============================================================
# BASIC FUNCTIONS
# ============================================================

log() {
    echo "[virgozki] $*"
}

step() {
    LAST_STEP="$1"
    echo ""
    echo "============================================================"
    echo "[virgozki] STEP: $LAST_STEP"
    echo "============================================================"
}

# ============================================================
# DIRECTORY SETUP
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
# SHOW LISTENING PORTS
# ============================================================

show_ports() {
    echo ""
    echo "----- LISTENING PORTS -----"

    if command -v ss >/dev/null 2>&1; then
        ss -lntp 2>/dev/null || true
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntp 2>/dev/null || true
    fi

    echo "---------------------------"
    echo ""
}

# ============================================================
# SHOW LOG
# ============================================================

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

# ============================================================
# PROCESS CHECK
# ============================================================

check_pid() {
    NAME="$1"
    PID="${2:-}"

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

# ============================================================
# PORT CHECK
# ============================================================

port_open() {
    HOST="$1"
    PORT_TO_CHECK="$2"

    python3 - "$HOST" "$PORT_TO_CHECK" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

try:
    sock = socket.create_connection((host, port), timeout=1)
    sock.close()
    sys.exit(0)
except Exception:
    sys.exit(1)
PY
}

# ============================================================
# WAIT FOR PORT
# ============================================================

wait_for_port() {
    NAME="$1"
    HOST="$2"
    CHECK_PORT="$3"
    PID="$4"
    TIMEOUT="$5"

    END_TIME=$(( $(date +%s) + TIMEOUT ))

    while [ "$(date +%s)" -lt "$END_TIME" ]
    do
        if ! check_pid "$NAME" "$PID"; then
            echo "[virgozki] $NAME died before port $CHECK_PORT became ready"
            return 1
        fi

        if port_open "$HOST" "$CHECK_PORT"; then
            log "$NAME port $CHECK_PORT READY"
            return 0
        fi

        sleep 1
    done

    echo "[virgozki] $NAME port $CHECK_PORT FAILED"

    show_ports

    return 1
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {
    echo ""
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

    sleep 1

    for PID in \
        "${ENVOY_PID:-}" \
        "${HAPROXY_PID:-}" \
        "${OPENRESTY_PID:-}" \
        "${APACHE_PID:-}" \
        "${XRAY_PID:-}"
    do
        if [ -n "$PID" ]; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    done
}

# ============================================================
# EXIT HANDLER
# ============================================================

on_exit() {
    RC=$?

    if [ "$RC" -ne 0 ]; then

        echo ""
        echo "============================================================"
        echo " VIRGOZKI STARTUP FAILED"
        echo "============================================================"
        echo " EXIT CODE       : $RC"
        echo " LAST STEP       : $LAST_STEP"
        echo " CLOUD RUN PORT  : $PORT"
        echo " HAProxy         : $HAPROXY_PORT"
        echo " OpenResty       : $OPENRESTY_PORT"
        echo " Apache          : $APACHE_PORT"
        echo " HAProxy gRPC    : $HAPROXY_GRPC_PORT"
        echo " OpenResty gRPC  : $OPENRESTY_GRPC_PORT"
        echo "============================================================"

        show_ports

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

        echo "============================================================"
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
        echo "[virgozki] MISSING FILE: $FILE"
        exit 1
    fi
done

log "All required files are present"

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

log "All required binaries are available"

# ============================================================
# XRAY CONFIG TEST
# ============================================================

step "Testing Xray configuration"

if ! xray run \
    -test \
    -c /etc/xray/config.json \
    >"$LOG_DIR/xray-test.log" 2>&1
then
    echo "[virgozki] XRAY CONFIGURATION FAILED"
    cat "$LOG_DIR/xray-test.log"
    exit 1
fi

log "Xray configuration OK"

# ============================================================
# APACHE CONFIG TEST
# ============================================================

step "Testing Apache configuration"

if ! apache2ctl \
    -t \
    >"$LOG_DIR/apache-test.log" 2>&1
then
    echo "[virgozki] APACHE CONFIGURATION FAILED"
    cat "$LOG_DIR/apache-test.log"
    exit 1
fi

log "Apache configuration OK"

# ============================================================
# OPENRESTY CONFIG TEST
# ============================================================

step "Testing OpenResty configuration"

if ! openresty \
    -t \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty-test.log" 2>&1
then
    echo "[virgozki] OPENRESTY CONFIGURATION FAILED"
    cat "$LOG_DIR/openresty-test.log"
    exit 1
fi

log "OpenResty configuration OK"

# ============================================================
# HAPROXY CONFIG TEST
# ============================================================

step "Testing HAProxy configuration"

if ! haproxy \
    -c \
    -f /etc/haproxy/haproxy.cfg \
    >"$LOG_DIR/haproxy-test.log" 2>&1
then
    echo "[virgozki] HAPROXY CONFIGURATION FAILED"
    cat "$LOG_DIR/haproxy-test.log"
    exit 1
fi

log "HAProxy configuration OK"

# ============================================================
# CREATE ENVOY CONFIG
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

          normalize_path: true

          stream_idle_timeout: 3600s

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

              # gRPC traffic
              - match:
                  prefix: "/openresty/"
                  grpc: {}

                route:
                  cluster: haproxy_grpc
                  timeout: 3600s

              # Normal HTTP traffic
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

  # ==========================================================
  # HTTP -> HAProxy :8081
  # ==========================================================

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


  # ==========================================================
  # gRPC -> HAProxy :8084
  # ==========================================================

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

log "Envoy configuration generated"

# ============================================================
# ENVOY CONFIG TEST
# ============================================================

step "Testing Envoy configuration"

if ! envoy \
    --mode validate \
    -c /tmp/envoy-front.yaml \
    >"$LOG_DIR/envoy-test.log" 2>&1
then
    echo "[virgozki] ENVOY CONFIGURATION FAILED"
    cat "$LOG_DIR/envoy-test.log"
    exit 1
fi

log "Envoy configuration OK"

# ============================================================
# START XRAY
# ============================================================

step "Starting Xray"

xray run \
    -c /etc/xray/config.json \
    >"$LOG_DIR/xray.log" 2>&1 &

XRAY_PID=$!

sleep 2

if ! check_pid "Xray" "$XRAY_PID"; then
    echo "[virgozki] XRAY FAILED TO START"
    cat "$LOG_DIR/xray.log"
    exit 1
fi

log "Xray process started"

# ============================================================
# START APACHE
# ============================================================

step "Starting Apache"

apache2ctl \
    -D FOREGROUND \
    >"$LOG_DIR/apache.log" 2>&1 &

APACHE_PID=$!

sleep 2

if ! check_pid "Apache" "$APACHE_PID"; then
    echo "[virgozki] APACHE FAILED TO START"
    cat "$LOG_DIR/apache.log"
    exit 1
fi

if ! wait_for_port \
    "Apache" \
    "127.0.0.1" \
    "$APACHE_PORT" \
    "$APACHE_PID" \
    30
then
    echo "[virgozki] APACHE PORT FAILED"
    cat "$LOG_DIR/apache.log"
    exit 1
fi

log "Apache started on 127.0.0.1:${APACHE_PORT}"

# ============================================================
# START OPENRESTY
# ============================================================

step "Starting OpenResty"

openresty \
    -g "daemon off;" \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty.log" 2>&1 &

OPENRESTY_PID=$!

sleep 2

if ! check_pid "OpenResty" "$OPENRESTY_PID"; then
    echo "[virgozki] OPENRESTY FAILED TO START"
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

if ! wait_for_port \
    "OpenResty HTTP" \
    "127.0.0.1" \
    "$OPENRESTY_PORT" \
    "$OPENRESTY_PID" \
    30
then
    echo "[virgozki] OPENRESTY HTTP PORT FAILED"
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

if ! wait_for_port \
    "OpenResty gRPC" \
    "127.0.0.1" \
    "$OPENRESTY_GRPC_PORT" \
    "$OPENRESTY_PID" \
    30
then
    echo "[virgozki] OPENRESTY gRPC PORT FAILED"
    cat "$LOG_DIR/openresty.log"
    exit 1
fi

log "OpenResty started"

# ============================================================
# START HAPROXY
# ============================================================

step "Starting HAProxy"

haproxy \
    -f /etc/haproxy/haproxy.cfg \
    -db \
    >"$LOG_DIR/haproxy.log" 2>&1 &

HAPROXY_PID=$!

sleep 2

if ! check_pid "HAProxy" "$HAPROXY_PID"; then
    echo "[virgozki] HAPROXY FAILED TO START"
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

if ! wait_for_port \
    "HAProxy HTTP" \
    "127.0.0.1" \
    "$HAPROXY_PORT" \
    "$HAPROXY_PID" \
    30
then
    echo "[virgozki] HAPROXY HTTP PORT FAILED"
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

if ! wait_for_port \
    "HAProxy gRPC" \
    "127.0.0.1" \
    "$HAPROXY_GRPC_PORT" \
    "$HAPROXY_PID" \
    30
then
    echo "[virgozki] HAPROXY gRPC PORT FAILED"
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi

log "HAProxy started"

# ============================================================
# SHOW INTERNAL PORTS
# ============================================================

step "Checking internal listeners"

show_ports

# ============================================================
# START ENVOY
# ============================================================

step "Starting Envoy"

envoy \
    -c /tmp/envoy-front.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy.log" 2>&1 &

ENVOY_PID=$!

sleep 2

if ! check_pid "Envoy" "$ENVOY_PID"; then
    echo "[virgozki] ENVOY FAILED TO START"
    cat "$LOG_DIR/envoy.log"
    exit 1
fi

# ============================================================
# WAIT FOR CLOUD RUN PUBLIC PORT
# ============================================================

step "Waiting for Cloud Run public port ${PORT}"

if ! wait_for_port \
    "Envoy PUBLIC" \
    "127.0.0.1" \
    "$PORT" \
    "$ENVOY_PID" \
    60
then
    echo "[virgozki] ENVOY PUBLIC PORT FAILED"

    show_ports

    cat "$LOG_DIR/envoy.log"

    exit 1
fi

log "Cloud Run public port ${PORT} READY"

# ============================================================
# FINAL HEALTH CHECK
# ============================================================

step "Running final health checks"

check_pid "Envoy" "$ENVOY_PID"
check_pid "HAProxy" "$HAPROXY_PID"
check_pid "OpenResty" "$OPENRESTY_PID"
check_pid "Apache" "$APACHE_PID"
check_pid "Xray" "$XRAY_PID"

show_ports

# ============================================================
# STARTUP COMPLETE
# ============================================================

echo ""
echo "============================================================"
echo " VIRGOZKI 4-PROXY STACK RUNNING"
echo "============================================================"
echo ""
echo " Cloud Run      : 0.0.0.0:${PORT}"
echo " Envoy          : 0.0.0.0:${PORT}"
echo ""
echo " HAProxy HTTP   : 127.0.0.1:${HAPROXY_PORT}"
echo " HAProxy gRPC   : 127.0.0.1:${HAPROXY_GRPC_PORT}"
echo ""
echo " OpenResty HTTP : 127.0.0.1:${OPENRESTY_PORT}"
echo " OpenResty gRPC : 127.0.0.1:${OPENRESTY_GRPC_PORT}"
echo ""
echo " Apache         : 127.0.0.1:${APACHE_PORT}"
echo ""
echo " Xray           : running"
echo ""
echo " CHAIN:"
echo " Envoy"
echo "   -> HAProxy"
echo "   -> OpenResty"
echo "   -> Apache"
echo "   -> Xray"
echo ""
echo "============================================================"
echo ""

# ============================================================
# KEEP CONTAINER ALIVE
# ============================================================

while true
do
    if ! check_pid "Envoy" "$ENVOY_PID"; then
        echo "[virgozki] Envoy died"
        exit 1
    fi

    if ! check_pid "HAProxy" "$HAPROXY_PID"; then
        echo "[virgozki] HAProxy died"
        exit 1
    fi

    if ! check_pid "OpenResty" "$OPENRESTY_PID"; then
        echo "[virgozki] OpenResty died"
        exit 1
    fi

    if ! check_pid "Apache" "$APACHE_PID"; then
        echo "[virgozki] Apache died"
        exit 1
    fi

    if ! check_pid "Xray" "$XRAY_PID"; then
        echo "[virgozki] Xray died"
        exit 1
    fi

    sleep 5
done
