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
APACHE_CONFIG="/etc/apache2/conf-available/virgozki.conf"

ENVOY_CONFIG="/etc/envoy/envoy.yaml"

PIDS=()

cleanup() {
    echo "[entrypoint] Shutting down..."

    for pid in "${PIDS[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done

    sleep 2

    for pid in "${PIDS[@]:-}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT INT TERM

echo "========================================"
echo " Virgozki Multi-Proxy Container"
echo "========================================"
echo "[entrypoint] PORT=$PORT"
echo "[entrypoint] HAProxy HTTP=$HAPROXY_PORT"
echo "[entrypoint] OpenResty HTTP=$OPENRESTY_PORT"
echo "[entrypoint] Apache HTTP=$APACHE_PORT"
echo "[entrypoint] HAProxy gRPC=$HAPROXY_GRPC_PORT"
echo "[entrypoint] OpenResty gRPC=$OPENRESTY_GRPC_PORT"
echo "========================================"

mkdir -p \
    /tmp/virgozki \
    /tmp/virgozki-logs \
    /run/haproxy \
    /var/run/haproxy \
    /run/apache2 \
    /var/run/apache2 \
    /var/log/xray \
    /var/log/apache2 \
    /var/lock/apache2 \
    /etc/envoy

chmod 777 \
    /tmp/virgozki \
    /tmp/virgozki-logs \
    /run/haproxy \
    /var/run/haproxy \
    /run/apache2 \
    /var/run/apache2

echo "[entrypoint] Checking required files..."

for file in \
    "$XRAY_CONFIG" \
    "$NGINX_CONFIG" \
    "$HAPROXY_CONFIG" \
    "$APACHE_CONFIG"
do
    if [ ! -f "$file" ]; then
        echo "[ERROR] Missing file: $file"
        exit 1
    fi
done

echo "[entrypoint] Checking binaries..."

command -v xray >/dev/null 2>&1 || {
    echo "[ERROR] xray not found"
    exit 1
}

command -v envoy >/dev/null 2>&1 || {
    echo "[ERROR] envoy not found"
    exit 1
}

command -v haproxy >/dev/null 2>&1 || {
    echo "[ERROR] haproxy not found"
    exit 1
}

command -v nginx >/dev/null 2>&1 || {
    echo "[ERROR] nginx not found"
    exit 1
}

command -v apache2 >/dev/null 2>&1 || {
    echo "[ERROR] apache2 not found"
    exit 1
}

echo "[entrypoint] Validating Xray configuration..."

xray -test -config "$XRAY_CONFIG"

echo "[entrypoint] Validating OpenResty configuration..."

nginx -t -c "$NGINX_CONFIG"

echo "[entrypoint] Validating HAProxy configuration..."

haproxy -c -f "$HAPROXY_CONFIG"

echo "[entrypoint] Validating Apache configuration..."

apache2ctl -t

echo "[entrypoint] Generating Envoy configuration..."

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

          stat_prefix: public_http

          codec_type: AUTO

          access_log:
          - name: envoy.access_loggers.stdout
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog

          route_config:
            name: local_route

            virtual_hosts:
            - name: backend

              domains:
              - "*"

              routes:

              - match:
                  prefix: "/openresty/"
                  grpc: {}

                route:
                  cluster: haproxy_grpc
                  timeout: 3600s

                request_headers_to_add:
                - header:
                    key: X-Forwarded-Proto
                    value: "http"
                  append_action: OVERWRITE_IF_EXISTS_OR_ADD

                - header:
                    key: X-Forwarded-Port
                    value: "${PORT}"
                  append_action: OVERWRITE_IF_EXISTS_OR_ADD

              - match:
                  prefix: "/"

                route:
                  cluster: haproxy_http
                  timeout: 3600s

                request_headers_to_add:
                - header:
                    key: X-Forwarded-Proto
                    value: "http"
                  append_action: OVERWRITE_IF_EXISTS_OR_ADD

                - header:
                    key: X-Forwarded-Port
                    value: "${PORT}"
                  append_action: OVERWRITE_IF_EXISTS_OR_ADD

          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:

  - name: haproxy_http
    type: STATIC
    connect_timeout: 5s

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
    type: STATIC
    connect_timeout: 5s

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

admin:
  access_log_path: /tmp/envoy-admin-access.log

  address:
    socket_address:
      address: 127.0.0.1
      port_value: 9901

EOF

echo "[entrypoint] Envoy configuration generated."

echo "[entrypoint] Starting Xray..."

xray run \
    -config "$XRAY_CONFIG" \
    > /tmp/virgozki-logs/xray.log 2>&1 &

XRAY_PID=$!
PIDS+=("$XRAY_PID")

echo "[entrypoint] Xray PID=$XRAY_PID"

echo "[entrypoint] Starting Apache..."

apache2ctl -DFOREGROUND \
    > /tmp/virgozki-logs/apache.log 2>&1 &

APACHE_PID=$!
PIDS+=("$APACHE_PID")

echo "[entrypoint] Apache PID=$APACHE_PID"

echo "[entrypoint] Starting OpenResty..."

nginx \
    -c "$NGINX_CONFIG" \
    -g "daemon off;" \
    > /tmp/virgozki-logs/openresty.log 2>&1 &

NGINX_PID=$!
PIDS+=("$NGINX_PID")

echo "[entrypoint] OpenResty PID=$NGINX_PID"

echo "[entrypoint] Starting HAProxy..."

haproxy \
    -f "$HAPROXY_CONFIG" \
    -db \
    > /tmp/virgozki-logs/haproxy.log 2>&1 &

HAPROXY_PID=$!
PIDS+=("$HAPROXY_PID")

echo "[entrypoint] HAProxy PID=$HAPROXY_PID"

echo "[entrypoint] Waiting for internal services..."

wait_for_port() {
    local host="$1"
    local port="$2"
    local name="$3"

    for i in $(seq 1 60); do

        if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
            echo "[entrypoint] $name is ready on $host:$port"
            return 0
        fi

        sleep 1
    done

    echo "[ERROR] $name failed to listen on $host:$port"
    return 1
}

wait_for_port 127.0.0.1 "$APACHE_PORT" "Apache"
wait_for_port 127.0.0.1 "$OPENRESTY_PORT" "OpenResty"
wait_for_port 127.0.0.1 "$HAPROXY_PORT" "HAProxy HTTP"
wait_for_port 127.0.0.1 "$HAPROXY_GRPC_PORT" "HAProxy gRPC"

echo "[entrypoint] Starting Envoy on ${BIND_ADDR}:${PORT}..."

envoy \
    -c "$ENVOY_CONFIG" \
    --log-level warning \
    > /tmp/virgozki-logs/envoy.log 2>&1 &

ENVOY_PID=$!
PIDS+=("$ENVOY_PID")

echo "[entrypoint] Envoy PID=$ENVOY_PID"

wait_for_port "$BIND_ADDR" "$PORT" "Envoy"

echo "========================================"
echo " All services are running"
echo "========================================"
echo " Envoy       : ${BIND_ADDR}:${PORT}"
echo " HAProxy HTTP: 127.0.0.1:${HAPROXY_PORT}"
echo " OpenResty   : 127.0.0.1:${OPENRESTY_PORT}"
echo " Apache      : 127.0.0.1:${APACHE_PORT}"
echo " HAProxy gRPC: 127.0.0.1:${HAPROXY_GRPC_PORT}"
echo " OpenResty gRPC: 127.0.0.1:${OPENRESTY_GRPC_PORT}"
echo "========================================"

while true; do

    for pid in "${PIDS[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "[ERROR] Process $pid stopped."
            exit 1
        fi
    done

    sleep 5

done
