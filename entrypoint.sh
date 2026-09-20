#!/bin/sh

set -eu

# ============================================================
# VIRGOZKI 4-PROXY + gRPC
# Cloud Run
# ============================================================

PORT="${PORT:-8080}"
LOG_DIR="/tmp/virgozki-logs"

mkdir -p "$LOG_DIR"
mkdir -p /tmp/virgozki
mkdir -p /run/apache2
mkdir -p /var/run/apache2

# ============================================================
# PIDS
# ============================================================

XRAY_PID=""
OPENRESTY_PID=""
HAPROXY_PID=""
ENVOY_ENGINE_PID=""
APACHE_PID=""
ENVOY_FRONT_PID=""

# ============================================================
# LOG
# ============================================================

log() {
    echo "[virgozki] $*"
}

show_log() {
    NAME="$1"
    FILE="$LOG_DIR/$NAME.log"

    echo
    echo "============================================================"
    echo " $NAME"
    echo "============================================================"

    if [ -f "$FILE" ]; then
        cat "$FILE" 2>/dev/null || true
    else
        echo "No log file: $FILE"
    fi

    echo "============================================================"
}

# ============================================================
# CLEANUP
# ============================================================

cleanup() {

    log "Stopping services..."

    for PID in \
        "$ENVOY_FRONT_PID" \
        "$APACHE_PID" \
        "$ENVOY_ENGINE_PID" \
        "$HAPROXY_PID" \
        "$OPENRESTY_PID" \
        "$XRAY_PID"
    do
        if [ -n "$PID" ]; then
            kill -0 "$PID" 2>/dev/null && \
            kill "$PID" 2>/dev/null || true
        fi
    done
}

# ============================================================
# EXIT HANDLER
# ============================================================

on_exit() {

    RC=$?

    if [ "$RC" -ne 0 ]; then

        echo
        echo "============================================================"
        echo " VIRGOZKI STARTUP FAILED"
        echo " EXIT CODE: $RC"
        echo "============================================================"

        show_log "xray-test"
        show_log "xray"

        show_log "openresty-test"
        show_log "openresty"

        show_log "haproxy-test"
        show_log "haproxy"

        show_log "envoy-engine-test"
        show_log "envoy-engine"

        show_log "apache-test"
        show_log "apache"

        show_log "envoy-front-test"
        show_log "envoy-front"

        echo "============================================================"
    fi

    cleanup

    trap - EXIT

    exit "$RC"
}

trap on_exit EXIT
trap 'exit 143' INT TERM

# ============================================================
# HEADER
# ============================================================

echo
echo "============================================================"
echo " VIRGOZKI 4-PROXY + gRPC"
echo "============================================================"
echo " PORT        : $PORT"
echo " OpenResty   : 8101 / 8102"
echo " HAProxy     : 8201 / 8202"
echo " Envoy       : 8300"
echo " Apache      : 8400"
echo "============================================================"
echo

# ============================================================
# REQUIRED FILES
# ============================================================

log "Checking required files..."

for FILE in \
    /etc/xray/config.json \
    /etc/openresty/nginx.conf \
    /usr/local/openresty/nginx/html/index.html
do

    if [ ! -f "$FILE" ]; then
        echo "ERROR: Missing file: $FILE"
        exit 1
    fi

done

log "Required files: OK"

# ============================================================
# WAIT PORT
# ============================================================

wait_port() {

    HOST="$1"
    PORT_NUMBER="$2"
    NAME="$3"
    PID="$4"
    LOG_NAME="$5"

    COUNT=0

    while [ "$COUNT" -lt 120 ]; do

        if ! kill -0 "$PID" 2>/dev/null; then
            echo
            echo "ERROR: $NAME stopped before becoming ready."
            show_log "$LOG_NAME"
            exit 1
        fi

        if python3 - "$HOST" "$PORT_NUMBER" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.5)

try:
    s.connect((host, port))
    s.close()
    sys.exit(0)
except Exception:
    s.close()
    sys.exit(1)
PY
        then
            log "$NAME ready on $HOST:$PORT_NUMBER"
            return 0
        fi

        COUNT=$((COUNT + 1))
        sleep 0.5

    done

    echo
    echo "ERROR: $NAME did not become ready on $HOST:$PORT_NUMBER"
    show_log "$LOG_NAME"
    exit 1
}

# ============================================================
# XRAY
# ============================================================

log "Testing Xray configuration..."

if ! /usr/local/bin/xray run \
    -test \
    -config /etc/xray/config.json \
    >"$LOG_DIR/xray-test.log" 2>&1
then

    show_log "xray-test"
    exit 1
fi

log "Xray configuration: OK"

log "Starting Xray..."

/usr/local/bin/xray run \
    -config /etc/xray/config.json \
    >"$LOG_DIR/xray.log" 2>&1 &

XRAY_PID=$!

sleep 1

if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    show_log "xray"
    exit 1
fi

log "Xray PID: $XRAY_PID"

wait_port \
    127.0.0.1 \
    10000 \
    "Xray" \
    "$XRAY_PID" \
    "xray"

# ============================================================
# OPENRESTY
# ============================================================

log "Testing OpenResty..."

if ! openresty \
    -t \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty-test.log" 2>&1
then

    show_log "openresty-test"
    exit 1
fi

log "OpenResty configuration: OK"

log "Starting OpenResty..."

openresty \
    -g "daemon off;" \
    -c /etc/openresty/nginx.conf \
    >"$LOG_DIR/openresty.log" 2>&1 &

OPENRESTY_PID=$!

sleep 1

if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
    show_log "openresty"
    exit 1
fi

log "OpenResty PID: $OPENRESTY_PID"

wait_port 127.0.0.1 8101 \
    "OpenResty HTTP" \
    "$OPENRESTY_PID" \
    "openresty"

wait_port 127.0.0.1 8102 \
    "OpenResty gRPC" \
    "$OPENRESTY_PID" \
    "openresty"

# ============================================================
# HAPROXY
# ============================================================

log "Generating HAProxy configuration..."

cat > /tmp/haproxy.cfg <<'HAPROXY'
global
    log stdout format raw local0
    maxconn 4096
    stats socket /tmp/haproxy.sock mode 660 level admin

defaults
    log global
    mode http

    option dontlognull
    option http-keep-alive

    timeout connect 10s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s

frontend virgozki_http

    bind 127.0.0.1:8201

    acl trojan_xhttp path -i /virgozki-xhttp
    acl trojan_hu    path -i /virgozki-hu
    acl trojan_ws    path -i /virgozki

    acl vmess_xhttp path -i /vmess-virgozki-xhttp
    acl vmess_hu    path -i /vmess-virgozki-hu
    acl vmess_ws    path -i /vmess-virgozki

    acl vless_xhttp path -i /vless-virgozki-xhttp
    acl vless_hu    path -i /vless-virgozki-hu
    acl vless_ws    path -i /vless-virgozki

    acl ss_xhttp path -i /ss-virgozki-xhttp
    acl ss_hu    path -i /ss-virgozki-hu
    acl ss_ws    path -i /ss-virgozki

    use_backend trojan_xhttp if trojan_xhttp
    use_backend trojan_hu    if trojan_hu
    use_backend trojan_ws    if trojan_ws

    use_backend vmess_xhttp if vmess_xhttp
    use_backend vmess_hu    if vmess_hu
    use_backend vmess_ws    if vmess_ws

    use_backend vless_xhttp if vless_xhttp
    use_backend vless_hu    if vless_hu
    use_backend vless_ws    if vless_ws

    use_backend ss_xhttp if ss_xhttp
    use_backend ss_hu    if ss_hu
    use_backend ss_ws    if ss_ws

    http-request deny deny_status 404

frontend virgozki_grpc

    bind 127.0.0.1:8202 proto h2

    acl trojan_grpc path_beg -i /trojan-grpc
    acl vmess_grpc  path_beg -i /vmess-grpc
    acl vless_grpc  path_beg -i /vless-grpc
    acl ss_grpc     path_beg -i /ss-grpc

    use_backend trojan_grpc if trojan_grpc
    use_backend vmess_grpc  if vmess_grpc
    use_backend vless_grpc  if vless_grpc
    use_backend ss_grpc     if ss_grpc

    http-request deny deny_status 404

backend trojan_ws
    server xray 127.0.0.1:10000

backend trojan_hu
    server xray 127.0.0.1:10001

backend trojan_xhttp
    server xray 127.0.0.1:10002

backend vmess_ws
    server xray 127.0.0.1:10004

backend vmess_hu
    server xray 127.0.0.1:10005

backend vmess_xhttp
    server xray 127.0.0.1:10006

backend vless_ws
    server xray 127.0.0.1:10008

backend vless_hu
    server xray 127.0.0.1:10009

backend vless_xhttp
    server xray 127.0.0.1:10010

backend ss_ws
    server xray 127.0.0.1:10012

backend ss_hu
    server xray 127.0.0.1:10013

backend ss_xhttp
    server xray 127.0.0.1:10014

backend trojan_grpc
    mode http
    server xray 127.0.0.1:10003 proto h2

backend vmess_grpc
    mode http
    server xray 127.0.0.1:10007 proto h2

backend vless_grpc
    mode http
    server xray 127.0.0.1:10011 proto h2

backend ss_grpc
    mode http
    server xray 127.0.0.1:10015 proto h2
HAPROXY

log "Testing HAProxy..."

if ! haproxy \
    -c \
    -f /tmp/haproxy.cfg \
    >"$LOG_DIR/haproxy-test.log" 2>&1
then

    show_log "haproxy-test"
    exit 1
fi

log "HAProxy configuration: OK"

log "Starting HAProxy..."

haproxy \
    -db \
    -f /tmp/haproxy.cfg \
    >"$LOG_DIR/haproxy.log" 2>&1 &

HAPROXY_PID=$!

sleep 1

if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
    show_log "haproxy"
    exit 1
fi

log "HAProxy PID: $HAPROXY_PID"

wait_port 127.0.0.1 8201 \
    "HAProxy HTTP" \
    "$HAPROXY_PID" \
    "haproxy"

wait_port 127.0.0.1 8202 \
    "HAProxy gRPC" \
    "$HAPROXY_PID" \
    "haproxy"

# ============================================================
# INTERNAL ENVOY
# ============================================================

log "Generating internal Envoy configuration..."

cat > /tmp/envoy-engine.yaml <<'YAML'
static_resources:

  listeners:

  - name: virgozki_engine

    address:
      socket_address:
        address: 127.0.0.1
        port_value: 8300

    filter_chains:

    - filters:

      - name: envoy.filters.network.http_connection_manager

        typed_config:

          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager

          stat_prefix: virgozki_engine

          codec_type: AUTO

          stream_idle_timeout: 0s
          request_timeout: 0s

          upgrade_configs:

          - upgrade_type: websocket

          route_config:

            name: virgozki_engine_routes

            virtual_hosts:

            - name: local

              domains:
              - "*"

              routes:

              - match:
                  prefix: /virgozki-xhttp
                route:
                  cluster: trojan_xhttp

              - match:
                  prefix: /virgozki-hu
                route:
                  cluster: trojan_hu

              - match:
                  path: /virgozki
                route:
                  cluster: trojan_ws
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /vmess-virgozki-xhttp
                route:
                  cluster: vmess_xhttp

              - match:
                  prefix: /vmess-virgozki-hu
                route:
                  cluster: vmess_hu

              - match:
                  path: /vmess-virgozki
                route:
                  cluster: vmess_ws
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /vless-virgozki-xhttp
                route:
                  cluster: vless_xhttp

              - match:
                  prefix: /vless-virgozki-hu
                route:
                  cluster: vless_hu

              - match:
                  path: /vless-virgozki
                route:
                  cluster: vless_ws
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /ss-virgozki-xhttp
                route:
                  cluster: ss_xhttp

              - match:
                  prefix: /ss-virgozki-hu
                route:
                  cluster: ss_hu

              - match:
                  path: /ss-virgozki
                route:
                  cluster: ss_ws
                  upgrade_configs:
                  - upgrade_type: websocket

              - match:
                  prefix: /trojan-grpc
                route:
                  cluster: trojan_grpc

              - match:
                  prefix: /vmess-grpc
                route:
                  cluster: vmess_grpc

              - match:
                  prefix: /vless-grpc
                route:
                  cluster: vless_grpc

              - match:
                  prefix: /ss-grpc
                route:
                  cluster: ss_grpc

              - match:
                  prefix: /
                direct_response:
                  status: 404

          http_filters:

          - name: envoy.filters.http.router

            typed_config:

              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:

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

admin:
  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9902
YAML

log "Testing internal Envoy..."

if ! envoy \
    --mode validate \
    -c /tmp/envoy-engine.yaml \
    >"$LOG_DIR/envoy-engine-test.log" 2>&1
then

    show_log "envoy-engine-test"
    exit 1
fi

log "Internal Envoy configuration: OK"

log "Starting internal Envoy..."

envoy \
    -c /tmp/envoy-engine.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy-engine.log" 2>&1 &

ENVOY_ENGINE_PID=$!

sleep 1

if ! kill -0 "$ENVOY_ENGINE_PID" 2>/dev/null; then
    show_log "envoy-engine"
    exit 1
fi

log "Internal Envoy PID: $ENVOY_ENGINE_PID"

wait_port 127.0.0.1 8300 \
    "Internal Envoy" \
    "$ENVOY_ENGINE_PID" \
    "envoy-engine"

# ============================================================
# APACHE
# ============================================================

log "Preparing Apache..."

mkdir -p /run/apache2
mkdir -p /var/run/apache2

rm -f /etc/apache2/sites-enabled/*

cat > /etc/apache2/ports.conf <<'APACHEPORTS'
Listen 8400
APACHEPORTS

cat > /etc/apache2/sites-available/virgozki.conf <<'APACHE'
<VirtualHost 127.0.0.1:8400>

    ServerName localhost

    Protocols h2 h2c http/1.1

    H2Direct on
    H2Upgrade on
    H2OutputBuffering off

    ProxyRequests Off
    ProxyPreserveHost On

    ProxyTimeout 3600

    # ========================================================
    # gRPC
    # ========================================================

    ProxyPass        /trojan-grpc h2c://127.0.0.1:10003
    ProxyPassReverse /trojan-grpc http://127.0.0.1:10003

    ProxyPass        /vmess-grpc h2c://127.0.0.1:10007
    ProxyPassReverse /vmess-grpc http://127.0.0.1:10007

    ProxyPass        /vless-grpc h2c://127.0.0.1:10011
    ProxyPassReverse /vless-grpc http://127.0.0.1:10011

    ProxyPass        /ss-grpc h2c://127.0.0.1:10015
    ProxyPassReverse /ss-grpc http://127.0.0.1:10015

    # ========================================================
    # XHTTP
    # ========================================================

    ProxyPass        /virgozki-xhttp http://127.0.0.1:10002
    ProxyPassReverse /virgozki-xhttp http://127.0.0.1:10002

    ProxyPass        /vmess-virgozki-xhttp http://127.0.0.1:10006
    ProxyPassReverse /vmess-virgozki-xhttp http://127.0.0.1:10006

    ProxyPass        /vless-virgozki-xhttp http://127.0.0.1:10010
    ProxyPassReverse /vless-virgozki-xhttp http://127.0.0.1:10010

    ProxyPass        /ss-virgozki-xhttp http://127.0.0.1:10014
    ProxyPassReverse /ss-virgozki-xhttp http://127.0.0.1:10014

    # ========================================================
    # HTTP Upgrade
    # ========================================================

    ProxyPass        /virgozki-hu http://127.0.0.1:10001
    ProxyPassReverse /virgozki-hu http://127.0.0.1:10001

    ProxyPass        /vmess-virgozki-hu http://127.0.0.1:10005
    ProxyPassReverse /vmess-virgozki-hu http://127.0.0.1:10005

    ProxyPass        /vless-virgozki-hu http://127.0.0.1:10009
    ProxyPassReverse /vless-virgozki-hu http://127.0.0.1:10009

    ProxyPass        /ss-virgozki-hu http://127.0.0.1:10013
    ProxyPassReverse /ss-virgozki-hu http://127.0.0.1:10013

    # ========================================================
    # WebSocket
    # ========================================================

    ProxyPass        /virgozki ws://127.0.0.1:10000
    ProxyPassReverse /virgozki http://127.0.0.1:10000

    ProxyPass        /vmess-virgozki ws://127.0.0.1:10004
    ProxyPassReverse /vmess-virgozki http://127.0.0.1:10004

    ProxyPass        /vless-virgozki ws://127.0.0.1:10008
    ProxyPassReverse /vless-virgozki http://127.0.0.1:10008

    ProxyPass        /ss-virgozki ws://127.0.0.1:10012
    ProxyPassReverse /ss-virgozki http://127.0.0.1:10012

    <Location />
        Require all granted
    </Location>

    ErrorLog /dev/stderr
    CustomLog /dev/stdout combined

</VirtualHost>
APACHE

# ------------------------------------------------------------
# Apache modules
# ------------------------------------------------------------

a2enmod proxy >/dev/null 2>&1 || true
a2enmod proxy_http >/dev/null 2>&1 || true
a2enmod proxy_http2 >/dev/null 2>&1 || true
a2enmod proxy_wstunnel >/dev/null 2>&1 || true
a2enmod headers >/dev/null 2>&1 || true
a2enmod http2 >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Directly enable site
# ------------------------------------------------------------

ln -sf \
    /etc/apache2/sites-available/virgozki.conf \
    /etc/apache2/sites-enabled/virgozki.conf

# ------------------------------------------------------------
# Apache config test
# ------------------------------------------------------------

log "Testing Apache configuration..."

if ! apache2ctl \
    -t \
    >"$LOG_DIR/apache-test.log" 2>&1
then

    echo
    echo "ERROR: Apache configuration test failed."

    show_log "apache-test"

    exit 1
fi

log "Apache configuration: OK"

# ============================================================
# START APACHE
# ============================================================

log "Starting Apache..."

apache2ctl \
    -DFOREGROUND \
    >"$LOG_DIR/apache.log" 2>&1 &

APACHE_PID=$!

sleep 2

if ! kill -0 "$APACHE_PID" 2>/dev/null; then

    echo
    echo "ERROR: Apache stopped immediately."

    show_log "apache"

    exit 1
fi

log "Apache PID: $APACHE_PID"

wait_port 127.0.0.1 8400 \
    "Apache" \
    "$APACHE_PID" \
    "apache"

# ============================================================
# PUBLIC ENVOY
# ============================================================

log "Generating public Envoy configuration..."

cat > /tmp/envoy-front.yaml <<EOF
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

          stat_prefix: public_http

          codec_type: AUTO

          stream_idle_timeout: 0s
          request_timeout: 0s

          upgrade_configs:

          - upgrade_type: websocket

          route_config:

            name: public_routes

            virtual_hosts:

            - name: public

              domains:
              - "*"

              routes:

              - match:
                  prefix: /openresty/trojan-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /trojan-grpc

              - match:
                  prefix: /openresty/vmess-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /vmess-grpc

              - match:
                  prefix: /openresty/vless-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /vless-grpc

              - match:
                  prefix: /openresty/ss-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /ss-grpc

              - match:
                  prefix: /openresty/
                route:
                  cluster: openresty_http
                  prefix_rewrite: /

              - match:
                  prefix: /haproxy/trojan-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /trojan-grpc

              - match:
                  prefix: /haproxy/vmess-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /vmess-grpc

              - match:
                  prefix: /haproxy/vless-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /vless-grpc

              - match:
                  prefix: /haproxy/ss-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /ss-grpc

              - match:
                  prefix: /haproxy/
                route:
                  cluster: haproxy_http
                  prefix_rewrite: /

              - match:
                  prefix: /envoy/trojan-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /trojan-grpc

              - match:
                  prefix: /envoy/vmess-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /vmess-grpc

              - match:
                  prefix: /envoy/vless-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /vless-grpc

              - match:
                  prefix: /envoy/ss-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /ss-grpc

              - match:
                  prefix: /envoy/
                route:
                  cluster: envoy_http
                  prefix_rewrite: /

              - match:
                  prefix: /apache/trojan-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /trojan-grpc

              - match:
                  prefix: /apache/vmess-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /vmess-grpc

              - match:
                  prefix: /apache/vless-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /vless-grpc

              - match:
                  prefix: /apache/ss-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /ss-grpc

              - match:
                  prefix: /apache/
                route:
                  cluster: apache_http
                  prefix_rewrite: /

              - match:
                  path: /
                route:
                  cluster: openresty_http

              - match:
                  prefix: /
                direct_response:
                  status: 404

          http_filters:

          - name: envoy.filters.http.router

            typed_config:

              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:

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

  - name: envoy_http
    connect_timeout: 5s
    type: STATIC
    load_assignment:
      cluster_name: envoy_http
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 8300

  - name: envoy_grpc
    connect_timeout: 5s
    type: STATIC
    http2_protocol_options: {}
    load_assignment:
      cluster_name: envoy_grpc
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 8300

  - name: apache_http
    connect_timeout: 5s
    type: STATIC
    load_assignment:
      cluster_name: apache_http
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 8400

  - name: apache_grpc
    connect_timeout: 5s
    type: STATIC
    http2_protocol_options: {}
    load_assignment:
      cluster_name: apache_grpc
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 127.0.0.1
                port_value: 8400

admin:

  address:

    socket_address:
      address: 127.0.0.1
      port_value: 9901
EOF

# ============================================================
# PUBLIC ENVOY TEST
# ============================================================

log "Testing public Envoy..."

if ! envoy \
    --mode validate \
    -c /tmp/envoy-front.yaml \
    >"$LOG_DIR/envoy-front-test.log" 2>&1
then

    show_log "envoy-front-test"
    exit 1
fi

log "Public Envoy configuration: OK"

# ============================================================
# PUBLIC ENVOY
# ============================================================

log "Starting public Envoy on 0.0.0.0:$PORT..."

envoy \
    -c /tmp/envoy-front.yaml \
    --disable-hot-restart \
    --log-level info \
    >"$LOG_DIR/envoy-front.log" 2>&1 &

ENVOY_FRONT_PID=$!

sleep 2

if ! kill -0 "$ENVOY_FRONT_PID" 2>/dev/null; then

    echo
    echo "ERROR: Public Envoy stopped immediately."

    show_log "envoy-front"

    exit 1
fi

log "Public Envoy PID: $ENVOY_FRONT_PID"

wait_port \
    127.0.0.1 \
    "$PORT" \
    "Public Envoy" \
    "$ENVOY_FRONT_PID" \
    "envoy-front"

# ============================================================
# READY
# ============================================================

echo
echo "============================================================"
echo " VIRGOZKI STACK READY"
echo "============================================================"
echo " Public Envoy : 0.0.0.0:$PORT"
echo " OpenResty    : 8101 / 8102"
echo " HAProxy      : 8201 / 8202"
echo " Envoy        : 8300"
echo " Apache       : 8400"
echo " Xray         : 10000-10015"
echo "============================================================"
echo

# ============================================================
# MONITOR
# ============================================================

while true
do

    if ! kill -0 "$XRAY_PID" 2>/dev/null; then
        echo "ERROR: Xray stopped."
        show_log "xray"
        exit 1
    fi

    if ! kill -0 "$OPENRESTY_PID" 2>/dev/null; then
        echo "ERROR: OpenResty stopped."
        show_log "openresty"
        exit 1
    fi

    if ! kill -0 "$HAPROXY_PID" 2>/dev/null; then
        echo "ERROR: HAProxy stopped."
        show_log "haproxy"
        exit 1
    fi

    if ! kill -0 "$ENVOY_ENGINE_PID" 2>/dev/null; then
        echo "ERROR: Internal Envoy stopped."
        show_log "envoy-engine"
        exit 1
    fi

    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "ERROR: Apache stopped."
        show_log "apache"
        exit 1
    fi

    if ! kill -0 "$ENVOY_FRONT_PID" 2>/dev/null; then
        echo "ERROR: Public Envoy stopped."
        show_log "envoy-front"
        exit 1
    fi

    sleep 5

done
