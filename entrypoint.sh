#!/bin/sh

set -u

PORT="${PORT:-8080}"
LOG_DIR="/tmp/virgozki-logs"

mkdir -p \
    "$LOG_DIR" \
    /tmp/virgozki \
    /run/apache2 \
    /var/run/apache2 \
    /var/run/haproxy

chmod 755 "$LOG_DIR" /tmp/virgozki

XRAY_PID=""
OPENRESTY_PID=""
HAPROXY_PID=""
ENVOY_ENGINE_PID=""
APACHE_PID=""
ENVOY_FRONT_PID=""

LAST_STEP="STARTING"


# ==================================================
# LOGGING
# ==================================================

log() {
    echo "[virgozki] $*"
}

step() {
    LAST_STEP="$1"

    echo ""
    echo "=================================================="
    echo "[virgozki] STEP: $LAST_STEP"
    echo "=================================================="
}

show_log() {
    NAME="$1"

    echo ""
    echo "----- $NAME -----"

    if [ -f "$LOG_DIR/$NAME.log" ]; then
        cat "$LOG_DIR/$NAME.log"
    else
        echo "NO LOG FILE: $LOG_DIR/$NAME.log"
    fi
}


# ==================================================
# CLEANUP
# ==================================================

cleanup() {
    echo "[virgozki] Stopping services..."

    if [ -n "$ENVOY_FRONT_PID" ]; then
        kill "$ENVOY_FRONT_PID" 2>/dev/null || true
    fi

    if [ -n "$APACHE_PID" ]; then
        kill "$APACHE_PID" 2>/dev/null || true
    fi

    if [ -n "$ENVOY_ENGINE_PID" ]; then
        kill "$ENVOY_ENGINE_PID" 2>/dev/null || true
    fi

    if [ -n "$HAPROXY_PID" ]; then
        kill "$HAPROXY_PID" 2>/dev/null || true
    fi

    if [ -n "$OPENRESTY_PID" ]; then
        kill "$OPENRESTY_PID" 2>/dev/null || true
    fi

    if [ -n "$XRAY_PID" ]; then
        kill "$XRAY_PID" 2>/dev/null || true
    fi
}


on_exit() {
    RC=$?

    if [ "$RC" -ne 0 ]; then

        echo ""
        echo "##################################################"
        echo " VIRGOZKI STARTUP FAILED"
        echo " EXIT CODE : $RC"
        echo " LAST STEP : $LAST_STEP"
        echo " PORT      : $PORT"
        echo "##################################################"

        show_log envoy-front-test
        show_log envoy-front

        show_log xray-test
        show_log xray

        show_log openresty-test
        show_log openresty

        show_log haproxy-test
        show_log haproxy

        show_log envoy-engine-test
        show_log envoy-engine

        show_log apache-modules
        show_log apache-test
        show_log apache

        echo ""
        echo "##################################################"
        echo " END STARTUP ERROR"
        echo "##################################################"
    fi

    cleanup
    exit "$RC"
}


trap on_exit EXIT
trap 'exit 143' INT TERM


# ==================================================
# WAIT FOR PORT
# ==================================================

wait_port() {
    HOST="$1"
    CHECK_PORT="$2"
    NAME="$3"
    PID="$4"

    step "Waiting for $NAME on $HOST:$CHECK_PORT"

    python3 - "$HOST" "$CHECK_PORT" "$PID" "$NAME" <<'PY'
import socket
import sys
import time
import os

host = sys.argv[1]
port = int(sys.argv[2])
pid = int(sys.argv[3])
name = sys.argv[4]

deadline = time.time() + 60

while time.time() < deadline:

    try:
        with socket.create_connection(
            (host, port),
            timeout=1
        ):
            print(
                f"[virgozki] {name} is listening "
                f"on {host}:{port}"
            )
            sys.exit(0)

    except Exception:
        pass

    try:
        os.kill(pid, 0)
    except Exception:
        print(
            f"[virgozki] {name} process died "
            f"before port {port} opened"
        )
        sys.exit(1)

    time.sleep(1)

print(
    f"[virgozki] TIMEOUT waiting for "
    f"{name} on {host}:{port}"
)

sys.exit(1)
PY
}


# ==================================================
# CHECK FILES / BINARIES
# ==================================================

step "Checking required files"

for FILE in \
    /etc/xray/config.json \
    /etc/openresty/nginx.conf \
    /usr/local/openresty/nginx/html/index.html
do
    if [ ! -f "$FILE" ]; then
        echo "[virgozki] MISSING FILE: $FILE"
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

command -v haproxy >/dev/null 2>&1 || {
    echo "[virgozki] haproxy not found"
    exit 1
}

command -v envoy >/dev/null 2>&1 || {
    echo "[virgozki] envoy not found"
    exit 1
}

command -v apache2ctl >/dev/null 2>&1 || {
    echo "[virgozki] apache2ctl not found"
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    echo "[virgozki] python3 not found"
    exit 1
}

log "All required files and binaries OK"


# ==================================================
# PUBLIC ENVOY
# ==================================================
#
# ROOT /
#   -> OpenResty 8101
#
# /openresty/*
#   -> OpenResty
#
# /haproxy/*
#   -> HAProxy
#
# /envoy/*
#   -> Internal Envoy
#
# /apache/*
#   -> Apache
#
# ==================================================

step "Creating public Envoy configuration"

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

              # ==================================================
              # OPENRESTY gRPC
              # ==================================================

              - match:
                  prefix: "/openresty/trojan-grpc"
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: "/trojan-grpc"
                  timeout: 0s

              - match:
                  prefix: "/openresty/vmess-grpc"
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: "/vmess-grpc"
                  timeout: 0s

              - match:
                  prefix: "/openresty/vless-grpc"
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: "/vless-grpc"
                  timeout: 0s

              - match:
                  prefix: "/openresty/ss-grpc"
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: "/ss-grpc"
                  timeout: 0s


              # ==================================================
              # HAPROXY gRPC
              # ==================================================

              - match:
                  prefix: "/haproxy/trojan-grpc"
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: "/trojan-grpc"
                  timeout: 0s

              - match:
                  prefix: "/haproxy/vmess-grpc"
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: "/vmess-grpc"
                  timeout: 0s

              - match:
                  prefix: "/haproxy/vless-grpc"
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: "/vless-grpc"
                  timeout: 0s

              - match:
                  prefix: "/haproxy/ss-grpc"
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: "/ss-grpc"
                  timeout: 0s


              # ==================================================
              # INTERNAL ENVOY gRPC
              # ==================================================

              - match:
                  prefix: "/envoy/trojan-grpc"
                route:
                  cluster: envoy_engine
                  prefix_rewrite: "/trojan-grpc"
                  timeout: 0s

              - match:
                  prefix: "/envoy/vmess-grpc"
                route:
                  cluster: envoy_engine
                  prefix_rewrite: "/vmess-grpc"
                  timeout: 0s

              - match:
                  prefix: "/envoy/vless-grpc"
                route:
                  cluster: envoy_engine
                  prefix_rewrite: "/vless-grpc"
                  timeout: 0s

              - match:
                  prefix: "/envoy/ss-grpc"
                route:
                  cluster: envoy_engine
                  prefix_rewrite: "/ss-grpc"
                  timeout: 0s


              # ==================================================
              # APACHE gRPC
              # ==================================================

              - match:
                  prefix: "/apache/trojan-grpc"
                route:
                  cluster: apache
                  prefix_rewrite: "/trojan-grpc"
                  timeout: 0s

              - match:
                  prefix: "/apache/vmess-grpc"
                route:
                  cluster: apache
                  prefix_rewrite: "/vmess-grpc"
                  timeout: 0s

              - match:
                  prefix: "/apache/vless-grpc"
                route:
                  cluster: apache
                  prefix_rewrite: "/vless-grpc"
                  timeout: 0s

              - match:
                  prefix: "/apache/ss-grpc"
                route:
                  cluster: apache
                  prefix_rewrite: "/ss-grpc"
                  timeout: 0s


              # ==================================================
              # OPENRESTY
              # ==================================================

              - match:
                  prefix: "/openresty/"
                route:
                  cluster: openresty_http
                  prefix_rewrite: "/"
                  timeout: 0s


              # ==================================================
              # HAPROXY
              # ==================================================

              - match:
                  prefix: "/haproxy/"
                route:
                  cluster: haproxy_http
                  prefix_rewrite: "/"
                  timeout: 0s


              # ==================================================
              # INTERNAL ENVOY
              # ==================================================

              - match:
                  prefix: "/envoy/"
                route:
                  cluster: envoy_engine
                  prefix_rewrite: "/"
                  timeout: 0s


              # ==================================================
              # APACHE
              # ==================================================

              - match:
                  prefix: "/apache/"
                route:
                  cluster: apache
                  prefix_rewrite: "/"
                  timeout: 0s


              # ==================================================
              # ROOT PANEL
              #
              # IMPORTANT:
              # /
              # -> OpenResty 8101
              # -> index.html
              # ==================================================

              - match:
                  prefix: "/"
                route:
                  cluster: openresty_http
                  timeout: 0s


          http_filters:

          - name: envoy.filters.http.router

            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router


  # ==================================================
  # OPENRESTY HTTP
  # ==================================================

  - name: openresty_http

    connect_timeout: 5s

    type: STATIC

    load_assignment:

      cluster_name: openresty_http

      endpoints:

      - lb_endpoints:

        - endpoint:

            address:

              socket_address:
                address: 127.0.0.1
                port_value: 8101


  # ==================================================
  # OPENRESTY gRPC
  # ==================================================

  - name: openresty_grpc

    connect_timeout: 5s

    type: STATIC

    http2_protocol_options: {}

    load_assignment:

      cluster_name: openresty_grpc

      endpoints:

      - lb_endpoints:

        - endpoint:

            address:

              socket_address:
                address: 127.0.0.1
                port_value: 8102


  # ==================================================
  # HAPROXY HTTP
  # ==================================================

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
                port_value: 8201


  # ==================================================
  # HAPROXY gRPC
  # ==================================================

  - name: haproxy_grpc

    connect_timeout: 5s

    type: STATIC

    http2_protocol_options: {}

    load_assignment:

      cluster_name: haproxy_grpc

      endpoints:

      - lb_endpoints:

        - endpoint:

            address:

              socket_address:
                address: 127.0.0.1
                port_value: 8202


  # ==================================================
  # INTERNAL ENVOY
  # ==================================================

  - name: envoy_engine

    connect_timeout: 5s

    type: STATIC

    http2_protocol_options: {}

    load_assignment:

      cluster_name: envoy_engine

      endpoints:

      - lb_endpoints:

        - endpoint:

            address:

              socket_address:
                address: 127.0.0.1
                port_value: 8300


  # ==================================================
  # APACHE
  # ==================================================

  - name: apache

    connect_timeout: 5s

    type: STATIC

    http2_protocol_options: {}

    load_assignment:

      cluster_name: apache

      endpoints:

      - lb_endpoints:

        - endpoint:

            address:

              socket_address:
                address: 127.0.0.1
                port_value: 8400

YAML


step "Validating public Envoy"

if ! envoy \
    --mode validate \
    -c /tmp/envoy-front.yaml \
    >"$LOG_DIR/envoy-front-test.log" 2>&1
then

    echo "[virgozki] PUBLIC ENVOY VALIDATION FAILED"

    cat "$LOG_DIR/envoy-front-test.log"

    exit 1
fi

log "Public Envoy configuration OK"


# ==================================================
# START PUBLIC ENVOY
# ==================================================

step "Starting public Envoy on 0.0.0.0:$PORT"

envoy \
    -c /tmp/envoy-front.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy-front.log" 2>&1 &

ENVOY_FRONT_PID=$!


# ==================================================
# WAIT FOR CLOUD RUN PORT
# ==================================================

step "Waiting for Cloud Run port $PORT"

python3 - "$PORT" "$ENVOY_FRONT_PID" <<'PY'
import socket
import sys
import time
import os

port = int(sys.argv[1])
pid = int(sys.argv[2])

deadline = time.time() + 60

while time.time() < deadline:

    try:
        with socket.create_connection(
            ("127.0.0.1", port),
            timeout=1
        ):
            print(
                f"[virgozki] PUBLIC PORT {port} READY"
            )
            sys.exit(0)

    except Exception:
        pass

    try:
        os.kill(pid, 0)
    except Exception:
        print("[virgozki] PUBLIC ENVOY STOPPED")
        sys.exit(1)

    time.sleep(1)

print(
    f"[virgozki] PUBLIC PORT {port} FAILED"
)

sys.exit(1)
PY


log "CLOUD RUN PORT READY: 0.0.0.0:$PORT"


# ==================================================
# XRAY
# ==================================================

step "Testing Xray configuration"

if ! xray run \
    -test \
    -config /etc/xray/config.json \
    >"$LOG_DIR/xray-test.log" 2>&1
then

    echo "[virgozki] XRAY CONFIGURATION FAILED"

    cat "$LOG_DIR/xray-test.log"

    exit 1
fi

log "Xray configuration OK"


step "Starting Xray"

xray run \
    -config /etc/xray/config.json \
    >"$LOG_DIR/xray.log" 2>&1 &

XRAY_PID=$!


wait_port \
    127.0.0.1 \
    10000 \
    "Xray" \
    "$XRAY_PID"


# ==================================================
# OPENRESTY
# ==================================================

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


step "Starting OpenResty"

openresty \
    -g "daemon off;" \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty.log" 2>&1 &

OPENRESTY_PID=$!


wait_port \
    127.0.0.1 \
    8101 \
    "OpenResty HTTP" \
    "$OPENRESTY_PID"


# ==================================================
# HAPROXY
# ==================================================

step "Creating HAProxy configuration"

cat > /tmp/haproxy.cfg <<'HAPROXY'

global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http

    option httplog
    option dontlognull

    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s


# ==================================================
# HTTP
# ==================================================

frontend virgozki_http

    bind 127.0.0.1:8201

    acl trojan_ws path -i /virgozki
    acl trojan_hu path -i /virgozki-hu
    acl trojan_xhttp path -i /virgozki-xhttp

    acl vmess_ws path -i /vmess-virgozki
    acl vmess_hu path -i /vmess-virgozki-hu
    acl vmess_xhttp path -i /vmess-virgozki-xhttp

    acl vless_ws path -i /vless-virgozki
    acl vless_hu path -i /vless-virgozki-hu
    acl vless_xhttp path -i /vless-virgozki-xhttp

    acl ss_ws path -i /ss-virgozki
    acl ss_hu path -i /ss-virgozki-hu
    acl ss_xhttp path -i /ss-virgozki-xhttp

    use_backend x_trojan_ws if trojan_ws
    use_backend x_trojan_hu if trojan_hu
    use_backend x_trojan_xhttp if trojan_xhttp

    use_backend x_vmess_ws if vmess_ws
    use_backend x_vmess_hu if vmess_hu
    use_backend x_vmess_xhttp if vmess_xhttp

    use_backend x_vless_ws if vless_ws
    use_backend x_vless_hu if vless_hu
    use_backend x_vless_xhttp if vless_xhttp

    use_backend x_ss_ws if ss_ws
    use_backend x_ss_hu if ss_hu
    use_backend x_ss_xhttp if ss_xhttp

    http-request return status 404


# ==================================================
# gRPC
# ==================================================

frontend virgozki_grpc

    bind 127.0.0.1:8202

    acl trojan_grpc path_beg -i /trojan-grpc
    acl vmess_grpc path_beg -i /vmess-grpc
    acl vless_grpc path_beg -i /vless-grpc
    acl ss_grpc path_beg -i /ss-grpc

    use_backend x_trojan_grpc if trojan_grpc
    use_backend x_vmess_grpc if vmess_grpc
    use_backend x_vless_grpc if vless_grpc
    use_backend x_ss_grpc if ss_grpc

    http-request return status 404


# ==================================================
# TROJAN
# ==================================================

backend x_trojan_ws
    server xray 127.0.0.1:10000 check

backend x_trojan_hu
    server xray 127.0.0.1:10001 check

backend x_trojan_xhttp
    server xray 127.0.0.1:10002 check

backend x_trojan_grpc
    server xray 127.0.0.1:10003 check


# ==================================================
# VMESS
# ==================================================

backend x_vmess_ws
    server xray 127.0.0.1:10004 check

backend x_vmess_hu
    server xray 127.0.0.1:10005 check

backend x_vmess_xhttp
    server xray 127.0.0.1:10006 check

backend x_vmess_grpc
    server xray 127.0.0.1:10007 check


# ==================================================
# VLESS
# ==================================================

backend x_vless_ws
    server xray 127.0.0.1:10008 check

backend x_vless_hu
    server xray 127.0.0.1:10009 check

backend x_vless_xhttp
    server xray 127.0.0.1:10010 check

backend x_vless_grpc
    server xray 127.0.0.1:10011 check


# ==================================================
# SHADOWSOCKS
# ==================================================

backend x_ss_ws
    server xray 127.0.0.1:10012 check

backend x_ss_hu
    server xray 127.0.0.1:10013 check

backend x_ss_xhttp
    server xray 127.0.0.1:10014 check

backend x_ss_grpc
    server xray 127.0.0.1:10015 check

HAPROXY


step "Testing HAProxy configuration"

if ! haproxy \
    -c \
    -f /tmp/haproxy.cfg \
    >"$LOG_DIR/haproxy-test.log" 2>&1
then

    echo "[virgozki] HAPROXY CONFIGURATION FAILED"

    cat "$LOG_DIR/haproxy-test.log"

    exit 1
fi

log "HAProxy configuration OK"


step "Starting HAProxy"

haproxy \
    -W \
    -db \
    -f /tmp/haproxy.cfg \
    >"$LOG_DIR/haproxy.log" 2>&1 &

HAPROXY_PID=$!


wait_port \
    127.0.0.1 \
    8201 \
    "HAProxy HTTP" \
    "$HAPROXY_PID"


# ==================================================
# INTERNAL ENVOY
# ==================================================

step "Creating internal Envoy configuration"

cat > /tmp/envoy-engine.yaml <<'YAML'

static_resources:

  listeners:

  - name: internal_engine

    address:

      socket_address:
        address: 127.0.0.1
        port_value: 8300

    filter_chains:

    - filters:

      - name: envoy.filters.network.http_connection_manager

        typed_config:

          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager

          stat_prefix: internal

          codec_type: AUTO

          route_config:

            name: internal_routes

            virtual_hosts:

            - name: internal

              domains:
              - "*"

              routes:

              - match:
                  prefix: "/trojan-grpc"
                route:
                  cluster: trojan_grpc
                  timeout: 0s

              - match:
                  prefix: "/vmess-grpc"
                route:
                  cluster: vmess_grpc
                  timeout: 0s

              - match:
                  prefix: "/vless-grpc"
                route:
                  cluster: vless_grpc
                  timeout: 0s

              - match:
                  prefix: "/ss-grpc"
                route:
                  cluster: ss_grpc
                  timeout: 0s

              - match:
                  path: "/virgozki"
                route:
                  cluster: trojan_ws
                  timeout: 0s

              - match:
                  prefix: "/virgozki-hu"
                route:
                  cluster: trojan_hu
                  timeout: 0s

              - match:
                  prefix: "/virgozki-xhttp"
                route:
                  cluster: trojan_xhttp
                  timeout: 0s

              - match:
                  path: "/vmess-virgozki"
                route:
                  cluster: vmess_ws
                  timeout: 0s

              - match:
                  prefix: "/vmess-virgozki-hu"
                route:
                  cluster: vmess_hu
                  timeout: 0s

              - match:
                  prefix: "/vmess-virgozki-xhttp"
                route:
                  cluster: vmess_xhttp
                  timeout: 0s

              - match:
                  path: "/vless-virgozki"
                route:
                  cluster: vless_ws
                  timeout: 0s

              - match:
                  prefix: "/vless-virgozki-hu"
                route:
                  cluster: vless_hu
                  timeout: 0s

              - match:
                  prefix: "/vless-virgozki-xhttp"
                route:
                  cluster: vless_xhttp
                  timeout: 0s

              - match:
                  path: "/ss-virgozki"
                route:
                  cluster: ss_ws
                  timeout: 0s

              - match:
                  prefix: "/ss-virgozki-hu"
                route:
                  cluster: ss_hu
                  timeout: 0s

              - match:
                  prefix: "/ss-virgozki-xhttp"
                route:
                  cluster: ss_xhttp
                  timeout: 0s

              - match:
                  prefix: "/"
                direct_response:
                  status: 404


          http_filters:

          - name: envoy.filters.http.router

            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router


  # ==================================================
  # TROJAN
  # ==================================================

  - name: trojan_ws
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: trojan_ws

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10000


  - name: trojan_hu
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: trojan_hu

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10001


  - name: trojan_xhttp
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: trojan_xhttp

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10002


  - name: trojan_grpc
    connect_timeout: 5s
    type: STATIC

    http2_protocol_options: {}

    load_assignment:
      cluster_name: trojan_grpc

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10003


  # ==================================================
  # VMESS
  # ==================================================

  - name: vmess_ws
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: vmess_ws

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10004


  - name: vmess_hu
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: vmess_hu

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10005


  - name: vmess_xhttp
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: vmess_xhttp

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10006


  - name: vmess_grpc
    connect_timeout: 5s
    type: STATIC

    http2_protocol_options: {}

    load_assignment:
      cluster_name: vmess_grpc

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10007


  # ==================================================
  # VLESS
  # ==================================================

  - name: vless_ws
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: vless_ws

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10008


  - name: vless_hu
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: vless_hu

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10009


  - name: vless_xhttp
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: vless_xhttp

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10010


  - name: vless_grpc
    connect_timeout: 5s
    type: STATIC

    http2_protocol_options: {}

    load_assignment:
      cluster_name: vless_grpc

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10011


  # ==================================================
  # SHADOWSOCKS
  # ==================================================

  - name: ss_ws
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: ss_ws

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10012


  - name: ss_hu
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: ss_hu

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10013


  - name: ss_xhttp
    connect_timeout: 5s
    type: STATIC

    load_assignment:
      cluster_name: ss_xhttp

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10014


  - name: ss_grpc
    connect_timeout: 5s
    type: STATIC

    http2_protocol_options: {}

    load_assignment:
      cluster_name: ss_grpc

      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 10015

YAML


step "Testing internal Envoy configuration"

if ! envoy \
    --mode validate \
    -c /tmp/envoy-engine.yaml \
    >"$LOG_DIR/envoy-engine-test.log" 2>&1
then

    echo "[virgozki] INTERNAL ENVOY CONFIGURATION FAILED"

    cat "$LOG_DIR/envoy-engine-test.log"

    exit 1
fi

log "Internal Envoy configuration OK"


step "Starting internal Envoy"

envoy \
    -c /tmp/envoy-engine.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy-engine.log" 2>&1 &

ENVOY_ENGINE_PID=$!


wait_port \
    127.0.0.1 \
    8300 \
    "Internal Envoy" \
    "$ENVOY_ENGINE_PID"


# ==================================================
# APACHE
# ==================================================

step "Preparing Apache"

mkdir -p \
    /run/apache2 \
    /var/run/apache2


cat > /etc/apache2/ports.conf <<'APACHEPORTS'
Listen 8400
APACHEPORTS


cat > /etc/apache2/sites-available/virgozki.conf <<'VHOST'

<VirtualHost 127.0.0.1:8400>

    ServerName localhost

    Protocols h2 h2c http/1.1

    H2Direct on
    H2Upgrade on
    H2OutputBuffering off

    ProxyRequests Off
    ProxyPreserveHost On

    ProxyTimeout 3600

    # ==================================================
    # gRPC
    # ==================================================

    ProxyPass        /trojan-grpc h2c://127.0.0.1:10003/trojan-grpc
    ProxyPassReverse /trojan-grpc h2c://127.0.0.1:10003/trojan-grpc

    ProxyPass        /vmess-grpc h2c://127.0.0.1:10007/vmess-grpc
    ProxyPassReverse /vmess-grpc h2c://127.0.0.1:10007/vmess-grpc

    ProxyPass        /vless-grpc h2c://127.0.0.1:10011/vless-grpc
    ProxyPassReverse /vless-grpc h2c://127.0.0.1:10011/vless-grpc

    ProxyPass        /ss-grpc h2c://127.0.0.1:10015/ss-grpc
    ProxyPassReverse /ss-grpc h2c://127.0.0.1:10015/ss-grpc


    # ==================================================
    # XHTTP
    # ==================================================

    ProxyPass        /virgozki-xhttp http://127.0.0.1:10002/virgozki-xhttp
    ProxyPassReverse /virgozki-xhttp http://127.0.0.1:10002/virgozki-xhttp

    ProxyPass        /vmess-virgozki-xhttp http://127.0.0.1:10006/vmess-virgozki-xhttp
    ProxyPassReverse /vmess-virgozki-xhttp http://127.0.0.1:10006/vmess-virgozki-xhttp

    ProxyPass        /vless-virgozki-xhttp http://127.0.0.1:10010/vless-virgozki-xhttp
    ProxyPassReverse /vless-virgozki-xhttp http://127.0.0.1:10010/vless-virgozki-xhttp

    ProxyPass        /ss-virgozki-xhttp http://127.0.0.1:10014/ss-virgozki-xhttp
    ProxyPassReverse /ss-virgozki-xhttp http://127.0.0.1:10014/ss-virgozki-xhttp


    # ==================================================
    # HTTP UPGRADE
    # ==================================================

    ProxyPass        /virgozki-hu http://127.0.0.1:10001/virgozki-hu
    ProxyPassReverse /virgozki-hu http://127.0.0.1:10001/virgozki-hu

    ProxyPass        /vmess-virgozki-hu http://127.0.0.1:10005/vmess-virgozki-hu
    ProxyPassReverse /vmess-virgozki-hu http://127.0.0.1:10005/vmess-virgozki-hu

    ProxyPass        /vless-virgozki-hu http://127.0.0.1:10009/vless-virgozki-hu
    ProxyPassReverse /vless-virgozki-hu http://127.0.0.1:10009/vless-virgozki-hu

    ProxyPass        /ss-virgozki-hu http://127.0.0.1:10013/ss-virgozki-hu
    ProxyPassReverse /ss-virgozki-hu http://127.0.0.1:10013/ss-virgozki-hu


    # ==================================================
    # WEBSOCKET
    # ==================================================

    ProxyPass        /virgozki ws://127.0.0.1:10000/virgozki
    ProxyPassReverse /virgozki ws://127.0.0.1:10000/virgozki

    ProxyPass        /vmess-virgozki ws://127.0.0.1:10004/vmess-virgozki
    ProxyPassReverse /vmess-virgozki ws://127.0.0.1:10004/vmess-virgozki

    ProxyPass        /vless-virgozki ws://127.0.0.1:10008/vless-virgozki
    ProxyPassReverse /vless-virgozki ws://127.0.0.1:10008/vless-virgozki

    ProxyPass        /ss-virgozki ws://127.0.0.1:10012/ss-virgozki
    ProxyPassReverse /ss-virgozki ws://127.0.0.1:10012/ss-virgozki


    <Location />
        Require all granted
    </Location>


    ErrorLog /dev/stderr
    CustomLog /dev/stdout combined

</VirtualHost>

VHOST


step "Activating Apache site"

rm -f /etc/apache2/sites-enabled/*

ln -sf \
    /etc/apache2/sites-available/virgozki.conf \
    /etc/apache2/sites-enabled/virgozki.conf


step "Enabling Apache modules"

if ! a2enmod \
    proxy \
    proxy_http \
    proxy_http2 \
    proxy_wstunnel \
    headers \
    http2 \
    >"$LOG_DIR/apache-modules.log" 2>&1
then

    echo "[virgozki] APACHE MODULE SETUP FAILED"

    cat "$LOG_DIR/apache-modules.log"

    exit 1
fi

log "Apache modules OK"


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


step "Starting Apache"

apache2ctl \
    -DFOREGROUND \
    >"$LOG_DIR/apache.log" 2>&1 &

APACHE_PID=$!


wait_port \
    127.0.0.1 \
    8400 \
    "Apache" \
    "$APACHE_PID"


# ==================================================
# FINAL CHECK
# ==================================================

step "Performing final service checks"

sleep 2


if ! kill -0 "$ENVOY_FRONT_PID" 2>/dev/null; then
    echo "[virgozki] PUBLIC ENVOY STOPPED"
    cat "$LOG_DIR/envoy-front.log"
    exit 1
fi


if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    echo "[virgozki] XRAY STOPPED"
    cat "$LOG_DIR/xray.log"
    exit 1
fi


if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
    echo "[virgozki] OPENRESTY STOPPED"
    cat "$LOG_DIR/openresty.log"
    exit 1
fi


if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
    echo "[virgozki] HAPROXY STOPPED"
    cat "$LOG_DIR/haproxy.log"
    exit 1
fi


if ! kill -0 "$ENVOY_ENGINE_PID" 2>/dev/null; then
    echo "[virgozki] INTERNAL ENVOY STOPPED"
    cat "$LOG_DIR/envoy-engine.log"
    exit 1
fi


if ! kill -0 "$APACHE_PID" 2>/dev/null; then
    echo "[virgozki] APACHE STOPPED"
    cat "$LOG_DIR/apache.log"
    exit 1
fi


# ==================================================
# PANEL TEST
# ==================================================

step "Testing panel through OpenResty"

if ! python3 - <<'PY'
import urllib.request

url = "http://127.0.0.1:8101/"

try:
    response = urllib.request.urlopen(url, timeout=5)

    status = response.status

    if status < 200 or status >= 500:
        print(
            f"[virgozki] PANEL TEST FAILED: HTTP {status}"
        )
        raise SystemExit(1)

    print(
        f"[virgozki] PANEL TEST OK: HTTP {status}"
    )

except Exception as e:
    print(
        f"[virgozki] PANEL TEST FAILED: {e}"
    )
    raise SystemExit(1)
PY
then

    echo "[virgozki] OpenResty panel test failed"

    cat "$LOG_DIR/openresty.log"

    exit 1
fi


# ==================================================
# READY
# ==================================================

step "VIRGOZKI FULLY READY"

log "=============================================="
log " VIRGOZKI READY"
log "=============================================="
log "Public Port : 0.0.0.0:$PORT"
log "Panel       : OpenResty :8101"
log "OpenResty   : 8101 / 8102"
log "HAProxy     : 8201 / 8202"
log "Envoy       : 8300"
log "Apache      : 8400"
log "=============================================="


# ==================================================
# PROCESS MONITOR
# ==================================================

while true
do

    if ! kill -0 "$ENVOY_FRONT_PID" 2>/dev/null; then
        echo "[virgozki] Public Envoy stopped"
        exit 1
    fi

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "[virgozki] Xray stopped"
        exit 1
    fi

    if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
        echo "[virgozki] OpenResty stopped"
        exit 1
    fi

    if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
        echo "[virgozki] HAProxy stopped"
        exit 1
    fi

    if ! kill -0 "$ENVOY_ENGINE_PID" 2>/dev/null; then
        echo "[virgozki] Internal Envoy stopped"
        exit 1
    fi

    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "[virgozki] Apache stopped"
        exit 1
    fi

    sleep 5

done
