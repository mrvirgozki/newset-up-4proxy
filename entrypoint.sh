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

# Full permissions
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
        show_log haproxy-test; show_log haproxy
        show_log envoy-engine-test; show_log envoy-engine
        show_log apache-modules; show_log apache-test; show_log apache
        echo ""; echo "=============================================="
    fi
    cleanup
    exit "$RC"
}

trap on_exit EXIT
trap 'exit 143' INT TERM

# ==================================================
# CHECK FILES & BINARIES
# ==================================================
step "Checking required files"
for FILE in \
    /etc/xray/config.json \
    /etc/openresty/nginx.conf \
    /usr/local/openresty/nginx/html/index.html
do
    [ ! -f "$FILE" ] && { echo "[virgozki] MISSING: $FILE"; exit 1; }
done

command -v xray >/dev/null 2>&1 || { echo "[virgozki] xray not found"; exit 1; }
command -v openresty >/dev/null 2>&1 || { echo "[virgozki] openresty not found"; exit 1; }
command -v haproxy >/dev/null 2>&1 || { echo "[virgozki] haproxy not found"; exit 1; }
command -v envoy >/dev/null 2>&1 || { echo "[virgozki] envoy not found"; exit 1; }
command -v apache2ctl >/dev/null 2>&1 || { echo "[virgozki] apache2ctl not found"; exit 1; }
log "All files & binaries OK"

# ==================================================
# PUBLIC ENVOY CONFIG
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
              - match: { prefix: "/openresty/" }
                route: { cluster: openresty_http, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/haproxy/" }
                route: { cluster: haproxy_http, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/envoy/" }
                route: { cluster: envoy_engine, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/" }
                route: { cluster: apache, timeout: 0s }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: { "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: openresty_http
    connect_timeout: 5s
    type: STATIC
    load_assignment: { cluster_name: openresty_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8101 } } } }] }] }
  - name: haproxy_http
    connect_timeout: 5s
    type: STATIC
    load_assignment: { cluster_name: haproxy_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8201 } } } }] }] }
  - name: envoy_engine
    connect_timeout: 5s
    type: STATIC
    load_assignment: { cluster_name: envoy_engine, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8300 } } } }] }] }
  - name: apache
    connect_timeout: 5s
    type: STATIC
    load_assignment: { cluster_name: apache, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8400 } } } }] }] }
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
# WAIT FOR PORT
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
# XRAY
# ==================================================
step "Testing Xray"
xray run -test -config /etc/xray/config.json >"$LOG_DIR/xray-test.log" 2>&1 || {
    echo "[virgozki] XRAY FAILED"; cat "$LOG_DIR/xray-test.log"; exit 1
}
log "Xray OK"

step "Starting Xray"
xray run -config /etc/xray/config.json >"$LOG_DIR/xray.log" 2>&1 &
XRAY_PID=$!

# ==================================================
# OPENRESTY
# ==================================================
step "Testing OpenResty"
openresty -t -c /etc/openresty/nginx.conf >"$LOG_DIR/openresty-test.log" 2>&1 || {
    echo "[virgozki] OPENRESTY FAILED"; cat "$LOG_DIR/openresty-test.log"; exit 1
}
log "OpenResty OK"

step "Starting OpenResty"
openresty -g "daemon off;" -c /etc/openresty/nginx.conf >"$LOG_DIR/openresty.log" 2>&1 &
OPENRESTY_PID=$!

# ==================================================
# HAPROXY
# ==================================================
step "Creating HAProxy config"
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
frontend virgozki_http
    bind 127.0.0.1:8201
    default_backend xray_http
frontend virgozki_grpc
    bind 127.0.0.1:8202
    default_backend xray_grpc
backend xray_http
    server xray 127.0.0.1:10000
backend xray_grpc
    server xray 127.0.0.1:10003
HAPROXY

step "Testing HAProxy"
haproxy -c -f /tmp/haproxy.cfg >"$LOG_DIR/haproxy-test.log" 2>&1 || {
    echo "[virgozki] HAPROXY FAILED"; cat "$LOG_DIR/haproxy-test.log"; exit 1
}
log "HAProxy OK"

step "Starting HAProxy"
haproxy -W -db -f /tmp/haproxy.cfg >"$LOG_DIR/haproxy.log" 2>&1 &
HAPROXY_PID=$!

# ==================================================
# INTERNAL ENVOY
# ==================================================
step "Creating internal Envoy"
cat > /tmp/envoy-engine.yaml <<'YAML'
static_resources:
  listeners:
  - name: internal_engine
    address: { socket_address: { address: 127.0.0.1, port_value: 8300 } }
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
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route: { cluster: xray_http, timeout: 0s }
          http_filters:
          - name: envoy.filters.http.router
            typed_config: { "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: xray_http
    connect_timeout: 5s
    type: STATIC
    load_assignment: { cluster_name: xray_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10000 } } } }] }] }
YAML

step "Testing internal Envoy"
envoy --mode validate -c /tmp/envoy-engine.yaml >"$LOG_DIR/envoy-engine-test.log" 2>&1 || {
    echo "[virgozki] INTERNAL ENVOY FAILED"; exit 1
}
log "Internal Envoy OK"

step "Starting internal Envoy"
envoy -c /tmp/envoy-engine.yaml --disable-hot-restart --log-level info >"$LOG_DIR/envoy-engine.log" 2>&1 &
ENVOY_ENGINE_PID=$!

# ==================================================
# APACHE (✅ FIXED MODULES + PROTOCOL)
# ==================================================
step "Preparing Apache"
mkdir -p /run/apache2 /var/run/apache2
cat > /etc/apache2/ports.conf <<'AP'
Listen 8400
AP

cat > /etc/apache2/sites-available/virgozki.conf <<'VHOST'
<VirtualHost 127.0.0.1:8400>
    ServerName localhost
    Protocols h2 h2c http/1.1
    H2Direct on
    H2Upgrade on

    ProxyRequests Off
    ProxyPreserveHost On
    ProxyTimeout 3600
    ProxyAddHeaders Off

    # ✅ WebSocket (TAMA)
    ProxyPass        /virgozki ws://127.0.0.1:10000/virgozki
    ProxyPassReverse /virgozki ws://127.0.0.1:10000/virgozki
    ProxyPass        /vmess-virgozki ws://127.0.0.1:10004/vmess-virgozki
    ProxyPassReverse /vmess-virgozki ws://127.0.0.1:10004/vmess-virgozki
    ProxyPass        /vless-virgozki ws://127.0.0.1:10008/vless-virgozki
    ProxyPassReverse /vless-virgozki ws://127.0.0.1:10008/vless-virgozki
    ProxyPass        /ss-virgozki ws://127.0.0.1:10012/ss-virgozki
    ProxyPassReverse /ss-virgozki ws://127.0.0.1:10012/ss-virgozki

    # ✅ HTTPUpgrade (Ginamit ang correct proxy protocol)
    ProxyPass        /virgozki-hu http://127.0.0.1:10001/virgozki-hu
    ProxyPassReverse /virgozki-hu http://127.0.0.1:10001/virgozki-hu
    ProxyPass        /vmess-virgozki-hu http://127.0.0.1:10005/vmess-virgozki-hu
    ProxyPassReverse /vmess-virgozki-hu http://127.0.0.1:10005/vmess-virgozki-hu
    ProxyPass        /vless-virgozki-hu http://127.0.0.1:10009/vless-virgozki-hu
    ProxyPassReverse /vless-virgozki-hu http://127.0.0.1:10009/vless-virgozki-hu
    ProxyPass        /ss-virgozki-hu http://127.0.0.1:10013/ss-virgozki-hu
    ProxyPassReverse /ss-virgozki-hu http://127.0.0.1:10013/ss-virgozki-hu

    # ✅ XHTTP
    ProxyPass        /virgozki-xhttp http://127.0.0.1:10002/virgozki-xhttp
    ProxyPassReverse /virgozki-xhttp http://127.0.0.1:10002/virgozki-xhttp
    ProxyPass        /vmess-virgozki-xhttp http://127.0.0.1:10006/vmess-virgozki-xhttp
    ProxyPassReverse /vmess-virgozki-xhttp http://127.0.0.1:10006/vmess-virgozki-xhttp
    ProxyPass        /vless-virgozki-xhttp http://127.0.0.1:10010/vless-virgozki-xhttp
    ProxyPassReverse /vless-virgozki-xhttp http://127.0.0.1:10010/vless-virgozki-xhttp
    ProxyPass        /ss-virgozki-xhttp http://127.0.0.1:10014/ss-virgozki-xhttp
    ProxyPassReverse /ss-virgozki-xhttp http://127.0.0.1:10014/ss-virgozki-xhttp

    # ✅ gRPC
    ProxyPass        /trojan-grpc h2c://127.0.0.1:10003/trojan-grpc
    ProxyPassReverse /trojan-grpc h2c://127.0.0.1:10003/trojan-grpc
    ProxyPass        /vmess-grpc h2c://127.0.0.1:10007/vmess-grpc
    ProxyPassReverse /vmess-grpc h2c://127.0.0.1:10007/vmess-grpc
    ProxyPass        /vless-grpc h2c://127.0.0.1:10011/vless-grpc
    ProxyPassReverse /vless-grpc h2c://127.0.0.1:10011/vless-grpc
    ProxyPass        /ss-grpc h2c://127.0.0.1:10015/ss-grpc
    ProxyPassReverse /ss-grpc h2c://127.0.0.1:10015/ss-grpc

    <Location />
        Require all granted
    </Location>

    ErrorLog /dev/stderr
    CustomLog /dev/stdout combined
</VirtualHost>
VHOST

rm -f /etc/apache2/sites-enabled/*
ln -sf /etc/apache2/sites-available/virgozki.conf /etc/apache2/sites-enabled/virgozki.conf

# ✅ ENABLE ALL REQUIRED MODULES (walang kulang na!)
step "Enabling Apache modules"
a2enmod proxy proxy_http proxy_http2 proxy_wstunnel headers rewrite http2 >"$LOG_DIR/apache-modules.log" 2>&1 || {
    echo "[virgozki] MODULES FAILED"; cat "$LOG_DIR/apache-modules.log"; exit 1
}
log "Apache modules OK"

step "Testing Apache"
apache2ctl -t >"$LOG_DIR/apache-test.log" 2>&1 || {
    echo "[virgozki] APACHE CONFIG FAILED"; cat "$LOG_DIR/apache-test.log"; exit 1
}
log "Apache config OK"

step "Starting Apache"
apache2ctl -DFOREGROUND >"$LOG_DIR/apache.log" 2>&1 &
APACHE_PID=$!

# ==================================================
# FINAL CHECKS
# ==================================================
sleep 2
kill -0 "$ENVOY_FRONT_PID" 2>/dev/null || { echo "[virgozki] ENVOY STOPPED"; exit 1; }
kill -0 "$XRAY_PID" 2>/dev/null || { echo "[virgozki] XRAY STOPPED"; exit 1; }
kill -0 "$OPENRESTY_PID" 2>/dev/null || { echo "[virgozki] OPENRESTY STOPPED"; exit 1; }
kill -0 "$HAPROXY_PID" 2>/dev/null || { echo "[virgozki] HAPROXY STOPPED"; exit 1; }
kill -0 "$ENVOY_ENGINE_PID" 2>/dev/null || { echo "[virgozki] INTERNAL ENVOY STOPPED"; exit 1; }
kill -0 "$APACHE_PID" 2>/dev/null || { echo "[virgozki] APACHE STOPPED"; exit 1; }

step "VIRGOZKI FULLY READY ✅"
log "Public Port: $PORT"
log "All Protocols: WS / HTTPUpgrade / XHTTP / gRPC"

# ==================================================
# MONITOR
# ==================================================
while true; do
    kill -0 "$ENVOY_FRONT_PID" 2>/dev/null || exit 1
    kill -0 "$XRAY_PID" 2>/dev/null || exit 1
    kill -0 "$OPENRESTY_PID" 2>/dev/null || exit 1
    kill -0 "$HAPROXY_PID" 2>/dev/null || exit 1
    kill -0 "$ENVOY_ENGINE_PID" 2>/dev/null || exit 1
    kill -0 "$APACHE_PID" 2>/dev/null || exit 1
    sleep 5
done
