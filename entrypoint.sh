#!/bin/bash
set -euo pipefail

PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

HAPROXY_PORT="${HAPROXY_PORT:-8081}"
OPENRESTY_PORT="${OPENRESTY_PORT:-8082}"
APACHE_PORT="${APACHE_PORT:-8083}"

HAPROXY_GRPC_PORT="${HAPROXY_GRPC_PORT:-8084}"
OPENRESTY_GRPC_PORT="${OPENRESTY_GRPC_PORT:-8085}"

XRAY_CONFIG="/etc/xray/config.json"
NGINX_CONFIG="/etc/openresty/nginx.conf"
HAPROXY_CONFIG="/etc/haproxy/haproxy.cfg"
ENVOY_CONFIG="/etc/envoy/envoy.yaml"

PIDS=()


cleanup() {
    echo "[entrypoint] shutting down..."

    for pid in "${PIDS[@]:-}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done

    sleep 3

    for pid in "${PIDS[@]:-}"; do
        kill -KILL "$pid" 2>/dev/null || true
    done
}

trap cleanup EXIT INT TERM


echo "======================================"
echo " Virgozki Proxy Stack"
echo "======================================"

mkdir -p \
/tmp/virgozki-logs \
/tmp/virgozki \
/etc/envoy \
/run/haproxy \
/var/run/apache2 \
/var/log/apache2 \
/var/log/xray


echo "[check] binaries"

command -v xray >/dev/null || { echo "❌ Missing xray"; exit 1; }
command -v nginx >/dev/null || { echo "❌ Missing nginx"; exit 1; }
command -v haproxy >/dev/null || { echo "❌ Missing haproxy"; exit 1; }
command -v apache2ctl >/dev/null || { echo "❌ Missing apache2ctl"; exit 1; }
command -v envoy >/dev/null || { echo "❌ Missing envoy"; exit 1; }


echo "[check] files"

for f in \
"$XRAY_CONFIG" \
"$NGINX_CONFIG" \
"$HAPROXY_CONFIG"
do
    if [ ! -f "$f" ]; then
        echo "Missing: $f"
        exit 1
    fi
done


echo "[test] Xray"

xray -test \
-config "$XRAY_CONFIG"


echo "[test] OpenResty"

nginx \
-t \
-c "$NGINX_CONFIG"


echo "[test] HAProxy"

haproxy \
-c \
-f "$HAPROXY_CONFIG"


echo "[start] Xray"

xray run \
-config "$XRAY_CONFIG" \
> /tmp/virgozki-logs/xray.log 2>&1 &

PIDS+=($!)
sleep 3


echo "[start] Apache"

apache2ctl \
-DFOREGROUND \
> /tmp/virgozki-logs/apache.log 2>&1 &

PIDS+=($!)
sleep 2


echo "[start] OpenResty"
# ✅ NAKINIG SA 127.0.0.1 LANG — HINDI NA KONFLIK SA PORT 8080
sed -i "s/listen 0.0.0.0:8080;/listen 127.0.0.1:$OPENRESTY_PORT;/" "$NGINX_CONFIG"
sed -i "s/listen 0.0.0.0:8085 http2;/listen 127.0.0.1:$OPENRESTY_GRPC_PORT http2;/" "$NGINX_CONFIG"

nginx \
-c "$NGINX_CONFIG" \
-g "daemon off;" \
> /tmp/virgozki-logs/openresty.log 2>&1 &

PIDS+=($!)
sleep 2


echo "[start] HAProxy"

haproxy \
-db \
-f "$HAPROXY_CONFIG" \
> /tmp/virgozki-logs/haproxy.log 2>&1 &

PIDS+=($!)
sleep 2


echo "[generate] Envoy"

cat > "$ENVOY_CONFIG" <<EOF

static_resources:

  listeners:

  - name: public_listener

    address:

      socket_address:

        address: ${BIND_ADDR}

        port_value: ${PORT}


    filter_chains:

    - filters:

      - name: envoy.filters.network.http_connection_manager

        typed_config:

          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager

          stat_prefix: proxy

          codec_type: AUTO


          route_config:

            name: local


            virtual_hosts:

            - name: backend

              domains:

              - "*"


              routes:

              - match:

                  prefix: "/"

                route:

                  cluster: haproxy_http

                  timeout: 3600s



          http_filters:

          - name: envoy.filters.http.router

            typed_config:

              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.Router



  clusters:

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

                port_value: ${HAPROXY_PORT}

admin:

  access_log_path: /tmp/envoy-admin.log

  address:

    socket_address:

      address: 127.0.0.1

      port_value: 9901

EOF


echo "[test] Envoy"

envoy \
--mode validate \
-c "$ENVOY_CONFIG"


echo "[start] Envoy"

envoy \
-c "$ENVOY_CONFIG" \
--log-level warning \
> /tmp/virgozki-logs/envoy.log 2>&1 &

PIDS+=($!)


sleep 5


echo "======================================"
echo " ALL SERVICES STARTED"
echo "======================================"

echo "Envoy        : $PORT"
echo "HAProxy      : $HAPROXY_PORT"
echo "OpenResty    : $OPENRESTY_PORT"
echo "Apache       : $APACHE_PORT"
echo "gRPC HAProxy : $HAPROXY_GRPC_PORT"
echo "gRPC Nginx   : $OPENRESTY_GRPC_PORT"


while true
do

    for pid in "${PIDS[@]}"
    do

        if ! kill -0 "$pid" 2>/dev/null
        then

            echo "Process stopped: $pid"

            echo "---- last 20 lines logs ----"

            tail -n 20 /tmp/virgozki-logs/*.log || true

            exit 1

        fi

    done

    sleep 5

done
