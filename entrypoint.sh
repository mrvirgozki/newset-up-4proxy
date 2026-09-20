#!/bin/sh
set -eu

PORT="${PORT:-8080}"
OPENRESTY_PORT="${OPENRESTY_PORT:-8081}"
LOG_DIR="/tmp/virgozki-logs"

mkdir -p \
    "$LOG_DIR" \
    /tmp/virgozki

chmod 777 "$LOG_DIR" /tmp/virgozki

XRAY_PID=""
OPENRESTY_PID=""
ENVOY_FRONT_PID=""

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

    if [ -n "${ENVOY_FRONT_PID:-}" ]; then
        kill "$ENVOY_FRONT_PID" 2>/dev/null || true
    fi

    if [ -n "${OPENRESTY_PID:-}" ]; then
        kill "$OPENRESTY_PID" 2>/dev/null || true
    fi

    if [ -n "${XRAY_PID:-}" ]; then
        kill "$XRAY_PID" 2>/dev/null || true
    fi
}

on_exit() {
    RC=$?

    if [ "$RC" -ne 0 ]; then
        echo ""
        echo "=============================================="
        echo " VIRGOZKI STARTUP FAILED"
        echo " EXIT CODE : $RC"
        echo " LAST STEP : $LAST_STEP"
        echo " PUBLIC PORT : $PORT"
        echo " OPENRESTY  : $OPENRESTY_PORT"
        echo "=============================================="

        show_log envoy-front-test
        show_log envoy-front
        show_log xray-test
        show_log xray
        show_log openresty-test
        show_log openresty

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
    /usr/share/nginx/html/index.html
do
    if [ ! -f "$FILE" ]; then
        echo "[virgozki] MISSING: $FILE"
        exit 1
    fi
done

command -v xray >/dev/null 2>&1 || {
    echo "[virgozki] xray not found"
    exit 1
}

command -v openresty >/dev/null 2>&1 || {
    echo "[virgozki] openresty not found"
    exit 1
}

command -v envoy >/dev/null 2>&1 || {
    echo "[virgozki] envoy not found"
    exit 1
}

log "All required files & binaries OK"


# ==================================================
# TEST XRAY CONFIG
# ==================================================

step "Testing Xray configuration"

xray test -c /etc/xray/config.json \
    >"$LOG_DIR/xray-test.log" 2>&1 || {
        echo "[virgozki] XRAY CONFIG VALIDATION FAILED"
        cat "$LOG_DIR/xray-test.log"
        exit 1
    }

log "Xray configuration OK"


# ==================================================
# TEST OPENRESTY CONFIG
# ==================================================

step "Testing OpenResty configuration"

openresty -t \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty-test.log" 2>&1 || {
        echo "[virgozki] OPENRESTY CONFIG VALIDATION FAILED"
        cat "$LOG_DIR/openresty-test.log"
        exit 1
    }

log "OpenResty configuration OK"


# ==================================================
# CREATE PUBLIC ENVOY CONFIG
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
              domains:
              - "*"

              routes:

              # OpenResty paths
              - match:
                  prefix: "/openresty/"
                route:
                  cluster: openresty_http
                  timeout: 3600s

              # Root / panel
              - match:
                  path: "/"
                route:
                  cluster: openresty_http
                  timeout: 3600s

          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router


  clusters:

  - name: openresty_http
    connect_timeout: 10s
    type: STATIC

    load_assignment:
      cluster_name: openresty_http

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: ${OPENRESTY_PORT}

YAML


# ==================================================
# TEST ENVOY
# ==================================================

step "Validating Envoy"

envoy --mode validate \
    -c /tmp/envoy-front.yaml \
    >"$LOG_DIR/envoy-front-test.log" 2>&1 || {
        echo "[virgozki] ENVOY VALIDATION FAILED"
        cat "$LOG_DIR/envoy-front-test.log"
        exit 1
    }

log "Envoy configuration OK"


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
# START ENVOY
# ==================================================

step "Starting Envoy on 0.0.0.0:${PORT}"

envoy \
    -c /tmp/envoy-front.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy-front.log" 2>&1 &

ENVOY_FRONT_PID=$!


# ==================================================
# WAIT FOR PUBLIC PORT
# ==================================================

step "Waiting for public port ${PORT}"

python3 - "$PORT" "$ENVOY_FRONT_PID" <<'PY'
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

if ! kill -0 "$ENVOY_FRONT_PID" 2>/dev/null; then
    echo "[virgozki] ENVOY STOPPED"
    cat "$LOG_DIR/envoy-front.log"
    exit 1
fi

if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
    echo "[virgozki] OPENRESTY STOPPED"
    cat "$LOG_DIR/openresty.log"
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

step "VIRGOZKI FULLY DEPLOYED & RUNNING"

log "Public port : ${PORT}"
log "OpenResty   : 127.0.0.1:${OPENRESTY_PORT}"
log "Panel       : /"
log "Proxy paths : /openresty/"
log "Envoy       : ${PORT} -> OpenResty ${OPENRESTY_PORT}"
log "Xray        : running"


# ==================================================
# MONITORING
# ==================================================

while true; do

    if ! kill -0 "$ENVOY_FRONT_PID" 2>/dev/null; then
        echo "[virgozki] ENVOY STOPPED"
        exit 1
    fi

    if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
        echo "[virgozki] OPENRESTY STOPPED"
        exit 1
    fi

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[virgozki] XRAY STOPPED"
        exit 1
    fi

    sleep 5

done
