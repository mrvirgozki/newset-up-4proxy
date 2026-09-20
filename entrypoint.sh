#!/bin/sh
set -eu

PORT="${PORT:-8080}"

XRAY_PID=""
OPENRESTY_PID=""
HAPROXY_PID=""
ENVOY_ENGINE_PID=""
APACHE_PID=""
FRONT_PID=""

LOG_DIR="/tmp/virgozki-logs"
mkdir -p "$LOG_DIR"

echo "=========================================="
echo " VIRGOZKI 4-PROXY + gRPC"
echo "=========================================="
echo "Public port : $PORT"
echo "OpenResty   : 8101 / 8102"
echo "HAProxy     : 8201 / 8202"
echo "Envoy       : 8300"
echo "Apache      : 8400"
echo "=========================================="

cleanup() {
    echo
    echo "Stopping services..."

    for pid in \
        "$FRONT_PID" \
        "$APACHE_PID" \
        "$ENVOY_ENGINE_PID" \
        "$HAPROXY_PID" \
        "$OPENRESTY_PID" \
        "$XRAY_PID"
    do
        if [ -n "${pid:-}" ]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

trap cleanup INT TERM EXIT


show_log() {
    name="$1"
    file="$LOG_DIR/$name.log"

    echo
    echo "========== $name LOG =========="

    if [ -f "$file" ]; then
        tail -n 200 "$file" || true
    else
        echo "No log file found: $file"
    fi

    echo "================================"
    echo
}


process_alive() {
    pid="$1"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    return 1
}


fail_service() {
    name="$1"
    pid="$2"

    echo
    echo "=========================================="
    echo " ERROR: $name FAILED"
    echo " PID: $pid"
    echo "=========================================="

    show_log "$name"

    echo "========== PROCESS STATUS =========="

    for item in \
        "Xray:$XRAY_PID" \
        "OpenResty:$OPENRESTY_PID" \
        "HAProxy:$HAPROXY_PID" \
        "EnvoyEngine:$ENVOY_ENGINE_PID" \
        "Apache:$APACHE_PID" \
        "PublicEnvoy:$FRONT_PID"
    do
        name2="${item%%:*}"
        pid2="${item#*:}"

        if [ -n "$pid2" ] && process_alive "$pid2"; then
            echo "$name2: RUNNING ($pid2)"
        else
            echo "$name2: STOPPED"
        fi
    done

    echo "==================================="

    exit 1
}


wait_port() {
    host="$1"
    port="$2"
    name="$3"
    pid="${4:-}"

    i=0

    while [ "$i" -lt 80 ]; do

        if [ -n "$pid" ]; then
            if ! process_alive "$pid"; then
                fail_service "$name" "$pid"
            fi
        fi

        if python3 - "$host" "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.5)

try:
    sock.connect((host, port))
    sock.close()
    sys.exit(0)
except Exception:
    sock.close()
    sys.exit(1)
PY
        then
            echo "OK: $name listening on $host:$port"
            return 0
        fi

        i=$((i + 1))
        sleep 0.25
    done

    echo
    echo "ERROR: $name did not listen on $host:$port"

    show_log "$name"

    return 1
}


start_xray() {
    echo
    echo "[1/6] Validating Xray..."

    xray run -test -c /etc/xray.json

    echo "[1/6] Starting Xray..."

    xray run -c /etc/xray.json \
        >"$LOG_DIR/xray.log" 2>&1 &

    XRAY_PID=$!

    echo "Xray PID: $XRAY_PID"

    sleep 1

    if ! process_alive "$XRAY_PID"; then
        fail_service "Xray" "$XRAY_PID"
    fi

    echo "OK: Xray running"
}


start_openresty() {
    echo
    echo "[2/6] Validating OpenResty..."

    openresty \
        -t \
        -c /usr/local/openresty/nginx/conf/nginx.conf

    echo "[2/6] Starting OpenResty..."

    openresty \
        -g 'daemon off;' \
        -c /usr/local/openresty/nginx/conf/nginx.conf \
        >"$LOG_DIR/openresty.log" 2>&1 &

    OPENRESTY_PID=$!

    echo "OpenResty PID: $OPENRESTY_PID"

    sleep 1

    if ! process_alive "$OPENRESTY_PID"; then
        fail_service "OpenResty" "$OPENRESTY_PID"
    fi

    wait_port 127.0.0.1 8101 \
        "OpenResty HTTP" \
        "$OPENRESTY_PID"

    wait_port 127.0.0.1 8102 \
        "OpenResty gRPC" \
        "$OPENRESTY_PID"
}


write_haproxy() {
cat > /tmp/haproxy.cfg <<'HAPROXY'
global
    maxconn 4096
    stats socket /tmp/haproxy.sock level admin

defaults
    log global
    mode http
    option dontlognull

    timeout connect 5s
    timeout client 3600s
    timeout server 3600s
    timeout tunnel 3600s
    timeout http-request 15s

frontend http1
    bind 127.0.0.1:8201
    mode http

    option http-server-close

    acl p_trojan_ws path -i /virgozki
    acl p_trojan_hu path -i /virgozki-hu
    acl p_trojan_xhttp path -i /virgozki-xhttp

    acl p_vmess_ws path -i /vmess-virgozki
    acl p_vmess_hu path -i /vmess-virgozki-hu
    acl p_vmess_xhttp path -i /vmess-virgozki-xhttp

    acl p_vless_ws path -i /vless-virgozki
    acl p_vless_hu path -i /vless-virgozki-hu
    acl p_vless_xhttp path -i /vless-virgozki-xhttp

    acl p_ss_ws path -i /ss-virgozki
    acl p_ss_hu path -i /ss-virgozki-hu
    acl p_ss_xhttp path -i /ss-virgozki-xhttp

    use_backend b_trojan_ws if p_trojan_ws
    use_backend b_trojan_hu if p_trojan_hu
    use_backend b_trojan_xhttp if p_trojan_xhttp

    use_backend b_vmess_ws if p_vmess_ws
    use_backend b_vmess_hu if p_vmess_hu
    use_backend b_vmess_xhttp if p_vmess_xhttp

    use_backend b_vless_ws if p_vless_ws
    use_backend b_vless_hu if p_vless_hu
    use_backend b_vless_xhttp if p_vless_xhttp

    use_backend b_ss_ws if p_ss_ws
    use_backend b_ss_hu if p_ss_hu
    use_backend b_ss_xhttp if p_ss_xhttp

    default_backend b_404


frontend grpc
    bind 127.0.0.1:8202 proto h2
    mode http

    acl g_trojan path_beg /trojan-grpc
    acl g_vmess path_beg /vmess-grpc
    acl g_vless path_beg /vless-grpc
    acl g_ss path_beg /ss-grpc

    use_backend b_trojan_grpc if g_trojan
    use_backend b_vmess_grpc if g_vmess
    use_backend b_vless_grpc if g_vless
    use_backend b_ss_grpc if g_ss

    default_backend b_404


backend b_404
    mode http
    http-request return status 404 \
        content-type text/plain \
        lf-string "not found\n"


backend b_trojan_ws
    server xray 127.0.0.1:10000 check

backend b_trojan_hu
    server xray 127.0.0.1:10001 check

backend b_trojan_xhttp
    server xray 127.0.0.1:10002 check


backend b_vmess_ws
    server xray 127.0.0.1:10004 check

backend b_vmess_hu
    server xray 127.0.0.1:10005 check

backend b_vmess_xhttp
    server xray 127.0.0.1:10006 check


backend b_vless_ws
    server xray 127.0.0.1:10008 check

backend b_vless_hu
    server xray 127.0.0.1:10009 check

backend b_vless_xhttp
    server xray 127.0.0.1:10010 check


backend b_ss_ws
    server xray 127.0.0.1:10012 check

backend b_ss_hu
    server xray 127.0.0.1:10013 check

backend b_ss_xhttp
    server xray 127.0.0.1:10014 check


backend b_trojan_grpc
    mode http
    server xray 127.0.0.1:10003 proto h2 check

backend b_vmess_grpc
    mode http
    server xray 127.0.0.1:10007 proto h2 check

backend b_vless_grpc
    mode http
    server xray 127.0.0.1:10011 proto h2 check

backend b_ss_grpc
    mode http
    server xray 127.0.0.1:10015 proto h2 check
HAPROXY
}


start_haproxy() {
    echo
    echo "[3/6] Creating HAProxy configuration..."

    write_haproxy

    echo "[3/6] Validating HAProxy..."

    haproxy -c -f /tmp/haproxy.cfg

    echo "[3/6] Starting HAProxy..."

    haproxy \
        -W \
        -db \
        -f /tmp/haproxy.cfg \
        >"$LOG_DIR/haproxy.log" 2>&1 &

    HAPROXY_PID=$!

    echo "HAProxy PID: $HAPROXY_PID"

    sleep 1

    if ! process_alive "$HAPROXY_PID"; then
        fail_service "HAProxy" "$HAPROXY_PID"
    fi

    wait_port 127.0.0.1 8201 \
        "HAProxy HTTP" \
        "$HAPROXY_PID"

    wait_port 127.0.0.1 8202 \
        "HAProxy gRPC" \
        "$HAPROXY_PID"
}


write_envoy_engine() {
cat > /tmp/envoy-engine.yaml <<'ENVOY'
static_resources:

  listeners:

  - name: engine

    address:
      socket_address:
        address: 127.0.0.1
        port_value: 8300

    filter_chains:

    - filters:

      - name: envoy.filters.network.http_connection_manager

        typed_config:

          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager

          stat_prefix: xray_engine

          codec_type: AUTO

          stream_idle_timeout: 0s

          request_timeout: 0s

          use_remote_address: true

          upgrade_configs:

          - upgrade_type: websocket

          route_config:

            name: xray_routes

            virtual_hosts:

            - name: all

              domains:
              - "*"

              routes:

              # XHTTP — must come before generic paths
              - match:
                  prefix: /virgozki-xhttp
                route:
                  cluster: trojan_xhttp
                  timeout: 0s

              - match:
                  prefix: /virgozki-hu
                route:
                  cluster: trojan_hu
                  timeout: 0s

              - match:
                  path: /virgozki
                route:
                  cluster: trojan_ws
                  timeout: 0s


              - match:
                  prefix: /vmess-virgozki-xhttp
                route:
                  cluster: vmess_xhttp
                  timeout: 0s

              - match:
                  prefix: /vmess-virgozki-hu
                route:
                  cluster: vmess_hu
                  timeout: 0s

              - match:
                  path: /vmess-virgozki
                route:
                  cluster: vmess_ws
                  timeout: 0s


              - match:
                  prefix: /vless-virgozki-xhttp
                route:
                  cluster: vless_xhttp
                  timeout: 0s

              - match:
                  prefix: /vless-virgozki-hu
                route:
                  cluster: vless_hu
                  timeout: 0s

              - match:
                  path: /vless-virgozki
                route:
                  cluster: vless_ws
                  timeout: 0s


              - match:
                  prefix: /ss-virgozki-xhttp
                route:
                  cluster: ss_xhttp
                  timeout: 0s

              - match:
                  prefix: /ss-virgozki-hu
                route:
                  cluster: ss_hu
                  timeout: 0s

              - match:
                  path: /ss-virgozki
                route:
                  cluster: ss_ws
                  timeout: 0s


              # gRPC
              - match:
                  prefix: /trojan-grpc
                route:
                  cluster: trojan_grpc
                  timeout: 0s
                  max_stream_duration:
                    grpc_timeout_header_max: 0s

              - match:
                  prefix: /vmess-grpc
                route:
                  cluster: vmess_grpc
                  timeout: 0s
                  max_stream_duration:
                    grpc_timeout_header_max: 0s

              - match:
                  prefix: /vless-grpc
                route:
                  cluster: vless_grpc
                  timeout: 0s
                  max_stream_duration:
                    grpc_timeout_header_max: 0s

              - match:
                  prefix: /ss-grpc
                route:
                  cluster: ss_grpc
                  timeout: 0s
                  max_stream_duration:
                    grpc_timeout_header_max: 0s


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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
    type: STATIC
    connect_timeout: 3s
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
ENVOY
}


start_envoy_engine() {
    echo
    echo "[4/6] Creating Envoy engine configuration..."

    write_envoy_engine

    echo "[4/6] Validating Envoy engine..."

    envoy \
        --mode validate \
        -c /tmp/envoy-engine.yaml

    echo "[4/6] Starting Envoy engine..."

    envoy \
        -c /tmp/envoy-engine.yaml \
        --log-level info \
        >"$LOG_DIR/envoy-engine.log" 2>&1 &

    ENVOY_ENGINE_PID=$!

    echo "Envoy engine PID: $ENVOY_ENGINE_PID"

    sleep 1

    if ! process_alive "$ENVOY_ENGINE_PID"; then
        fail_service "Envoy engine" "$ENVOY_ENGINE_PID"
    fi

    wait_port 127.0.0.1 8300 \
        "Envoy engine" \
        "$ENVOY_ENGINE_PID"
}


write_apache() {
cat > /tmp/apache-xray.conf <<'APACHE'
ServerRoot "/etc/apache2"

PidFile "/tmp/apache2.pid"

ServerName localhost

Listen 8400

IncludeOptional /etc/apache2/mods-enabled/*.load
IncludeOptional /etc/apache2/mods-enabled/*.conf

User www-data
Group www-data

Protocols h2 h2c http/1.1

H2Direct on
H2Upgrade on
H2OutputBuffering off

KeepAlive On
KeepAliveTimeout 5
MaxKeepAliveRequests 100

RequestReadTimeout header=15-30,MinRate=500

LimitRequestBody 67108864

ProxyRequests Off
ProxyPreserveHost On
ProxyTimeout 3600

ErrorLog /dev/stderr
CustomLog /dev/stdout combined

<VirtualHost *:8400>

    ServerName _default_

    DocumentRoot /usr/local/openresty/nginx/html

    <Directory "/usr/local/openresty/nginx/html">
        Require all granted
        AllowOverride None
    </Directory>


    # gRPC
    ProxyPass "/trojan-grpc" \
        "h2c://127.0.0.1:10003" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/vmess-grpc" \
        "h2c://127.0.0.1:10007" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/vless-grpc" \
        "h2c://127.0.0.1:10011" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/ss-grpc" \
        "h2c://127.0.0.1:10015" \
        connectiontimeout=3 timeout=3600


    # Trojan
    ProxyPass "/virgozki" \
        "http://127.0.0.1:10000" \
        connectiontimeout=3 timeout=3600 \
        upgrade=websocket

    ProxyPass "/virgozki-hu" \
        "http://127.0.0.1:10001" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/virgozki-xhttp" \
        "http://127.0.0.1:10002" \
        connectiontimeout=3 timeout=3600


    # VMess
    ProxyPass "/vmess-virgozki" \
        "http://127.0.0.1:10004" \
        connectiontimeout=3 timeout=3600 \
        upgrade=websocket

    ProxyPass "/vmess-virgozki-hu" \
        "http://127.0.0.1:10005" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/vmess-virgozki-xhttp" \
        "http://127.0.0.1:10006" \
        connectiontimeout=3 timeout=3600


    # VLESS
    ProxyPass "/vless-virgozki" \
        "http://127.0.0.1:10008" \
        connectiontimeout=3 timeout=3600 \
        upgrade=websocket

    ProxyPass "/vless-virgozki-hu" \
        "http://127.0.0.1:10009" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/vless-virgozki-xhttp" \
        "http://127.0.0.1:10010" \
        connectiontimeout=3 timeout=3600


    # Shadowsocks
    ProxyPass "/ss-virgozki" \
        "http://127.0.0.1:10012" \
        connectiontimeout=3 timeout=3600 \
        upgrade=websocket

    ProxyPass "/ss-virgozki-hu" \
        "http://127.0.0.1:10013" \
        connectiontimeout=3 timeout=3600

    ProxyPass "/ss-virgozki-xhttp" \
        "http://127.0.0.1:10014" \
        connectiontimeout=3 timeout=3600

</VirtualHost>
APACHE
}


start_apache() {
    echo
    echo "[5/6] Creating Apache configuration..."

    write_apache

    echo "[5/6] Validating Apache..."

    apache2 \
        -t \
        -f /tmp/apache-xray.conf

    echo "[5/6] Starting Apache..."

    apache2 \
        -DFOREGROUND \
        -f /tmp/apache-xray.conf \
        >"$LOG_DIR/apache.log" 2>&1 &

    APACHE_PID=$!

    echo "Apache PID: $APACHE_PID"

    sleep 1

    if ! process_alive "$APACHE_PID"; then
        fail_service "Apache" "$APACHE_PID"
    fi

    wait_port 127.0.0.1 8400 \
        "Apache httpd" \
        "$APACHE_PID"
}


write_front() {
cat > /tmp/envoy-front.yaml <<EOF
static_resources:

  listeners:

  - name: public

    address:
      socket_address:
        address: 0.0.0.0
        port_value: ${PORT}

    per_connection_buffer_limit_bytes: 1048576

    filter_chains:

    - filters:

      - name: envoy.filters.network.http_connection_manager

        typed_config:

          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager

          stat_prefix: public

          codec_type: AUTO

          stream_idle_timeout: 0s

          request_timeout: 0s

          use_remote_address: true

          normalize_path: true

          path_with_escaped_slashes_action: KEEP_UNCHANGED

          upgrade_configs:

          - upgrade_type: websocket

          route_config:

            name: public_routes

            virtual_hosts:

            - name: all

              domains:
              - "*"

              routes:

              # =========================
              # OPENRESTY gRPC
              # =========================

              - match:
                  prefix: /openresty/trojan-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /trojan-grpc
                  timeout: 0s

              - match:
                  prefix: /openresty/vmess-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /vmess-grpc
                  timeout: 0s

              - match:
                  prefix: /openresty/vless-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /vless-grpc
                  timeout: 0s

              - match:
                  prefix: /openresty/ss-grpc
                route:
                  cluster: openresty_grpc
                  prefix_rewrite: /ss-grpc
                  timeout: 0s


              - match:
                  prefix: /openresty/
                route:
                  cluster: openresty_http
                  prefix_rewrite: /
                  timeout: 0s


              # =========================
              # HAPROXY gRPC
              # =========================

              - match:
                  prefix: /haproxy/trojan-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /trojan-grpc
                  timeout: 0s

              - match:
                  prefix: /haproxy/vmess-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /vmess-grpc
                  timeout: 0s

              - match:
                  prefix: /haproxy/vless-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /vless-grpc
                  timeout: 0s

              - match:
                  prefix: /haproxy/ss-grpc
                route:
                  cluster: haproxy_grpc
                  prefix_rewrite: /ss-grpc
                  timeout: 0s


              - match:
                  prefix: /haproxy/
                route:
                  cluster: haproxy_http
                  prefix_rewrite: /
                  timeout: 0s


              # =========================
              # ENVOY gRPC
              # =========================

              - match:
                  prefix: /envoy/trojan-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /trojan-grpc
                  timeout: 0s

              - match:
                  prefix: /envoy/vmess-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /vmess-grpc
                  timeout: 0s

              - match:
                  prefix: /envoy/vless-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /vless-grpc
                  timeout: 0s

              - match:
                  prefix: /envoy/ss-grpc
                route:
                  cluster: envoy_grpc
                  prefix_rewrite: /ss-grpc
                  timeout: 0s


              - match:
                  prefix: /envoy/
                route:
                  cluster: envoy_http
                  prefix_rewrite: /
                  timeout: 0s


              # =========================
              # APACHE gRPC
              # =========================

              - match:
                  prefix: /apache/trojan-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /trojan-grpc
                  timeout: 0s

              - match:
                  prefix: /apache/vmess-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /vmess-grpc
                  timeout: 0s

              - match:
                  prefix: /apache/vless-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /vless-grpc
                  timeout: 0s

              - match:
                  prefix: /apache/ss-grpc
                route:
                  cluster: apache_grpc
                  prefix_rewrite: /ss-grpc
                  timeout: 0s


              - match:
                  prefix: /apache/
                route:
                  cluster: apache_http
                  prefix_rewrite: /
                  timeout: 0s


              # =========================
              # PANEL
              # =========================

              - match:
                  prefix: /
                route:
                  cluster: openresty_http
                  prefix_rewrite: /
                  timeout: 0s


          http_filters:

          - name: envoy.filters.http.router

            typed_config:

              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router


  # =========================
  # OPENRESTY
  # =========================

  clusters:

  - name: openresty_http
    type: STATIC
    connect_timeout: 3s

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
    type: STATIC
    connect_timeout: 3s

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


  # =========================
  # HAPROXY
  # =========================

  - name: haproxy_http
    type: STATIC
    connect_timeout: 3s

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
    type: STATIC
    connect_timeout: 3s

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


  # =========================
  # ENVOY
  # =========================

  - name: envoy_http
    type: STATIC
    connect_timeout: 3s

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
    type: STATIC
    connect_timeout: 3s

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


  # =========================
  # APACHE
  # =========================

  - name: apache_http
    type: STATIC
    connect_timeout: 3s

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
    type: STATIC
    connect_timeout: 3s

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
}


start_public_envoy() {
    echo
    echo "[6/6] Creating public Envoy configuration..."

    write_front

    echo "[6/6] Validating public Envoy..."

    envoy \
        --mode validate \
        -c /tmp/envoy-front.yaml

    echo "[6/6] Starting public Envoy on 0.0.0.0:$PORT..."

    envoy \
        -c /tmp/envoy-front.yaml \
        --log-level info \
        >"$LOG_DIR/envoy-front.log" 2>&1 &

    FRONT_PID=$!

    echo "Public Envoy PID: $FRONT_PID"

    sleep 1

    if ! process_alive "$FRONT_PID"; then
        fail_service "Public Envoy" "$FRONT_PID"
    fi

    wait_port \
        0.0.0.0 \
        "$PORT" \
        "Public Envoy" \
        "$FRONT_PID"

    echo
    echo "=========================================="
    echo " PUBLIC LISTENER READY"
    echo " PORT: $PORT"
    echo "=========================================="
}


monitor_processes() {
    echo
    echo "=========================================="
    echo " ALL SERVICES ARE RUNNING"
    echo "=========================================="
    echo "Xray PID         : $XRAY_PID"
    echo "OpenResty PID    : $OPENRESTY_PID"
    echo "HAProxy PID      : $HAPROXY_PID"
    echo "Envoy Engine PID : $ENVOY_ENGINE_PID"
    echo "Apache PID       : $APACHE_PID"
    echo "Public Envoy PID : $FRONT_PID"
    echo "Public PORT      : $PORT"
    echo "=========================================="

    while true; do

        if ! process_alive "$XRAY_PID"; then
            fail_service "Xray" "$XRAY_PID"
        fi

        if ! process_alive "$OPENRESTY_PID"; then
            fail_service "OpenResty" "$OPENRESTY_PID"
        fi

        if ! process_alive "$HAPROXY_PID"; then
            fail_service "HAProxy" "$HAPROXY_PID"
        fi

        if ! process_alive "$ENVOY_ENGINE_PID"; then
            fail_service "Envoy engine" "$ENVOY_ENGINE_PID"
        fi

        if ! process_alive "$APACHE_PID"; then
            fail_service "Apache" "$APACHE_PID"
        fi

        if ! process_alive "$FRONT_PID"; then
            fail_service "Public Envoy" "$FRONT_PID"
        fi

        sleep 5
    done
}


# ==========================================
# STARTUP
# ==========================================

start_xray

start_openresty

start_haproxy

start_envoy_engine

start_apache

start_public_envoy

monitor_processes
