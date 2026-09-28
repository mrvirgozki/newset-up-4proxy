#!/bin/bash
set -e

# ============================================================
# VIRGOZKI ENTRYPOINT SCRIPT
# Handles runtime dynamic configuration and supervisor startup
# ============================================================

PORT="${PORT:-8080}"
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

echo "[ENTRYPOINT] Initializing VIRGOZKI multi-proxy service..."
echo "[ENTRYPOINT] Target PORT: ${PORT}"
echo "[ENTRYPOINT] Target BIND_ADDR: ${BIND_ADDR}"

# Ensure runtime directories exist
mkdir -p /var/log/xray \
         /var/log/apache2 \
         /var/log/supervisor \
         /run/haproxy \
         /var/run/apache2 \
         /tmp/virgozki \
         /tmp/virgozki-logs

# Dynamically bind Envoy port if Cloud Run passes a custom PORT
if [ -f /etc/envoy/envoy.yaml ]; then
    sed -i "s/port_value: 8080/port_value: ${PORT}/g" /etc/envoy/envoy.yaml
    sed -i "s/address: 0.0.0.0/address: ${BIND_ADDR}/g" /etc/envoy/envoy.yaml
    echo "[ENTRYPOINT] Configured Envoy port to ${PORT}"
fi

# Clean up stale Apache PID files if container restarts
rm -f /var/run/apache2/apache2.pid /var/run/apache2/httpd.pid

# Validate core configurations at runtime
echo "[ENTRYPOINT] Validating configurations..."

/usr/local/bin/xray run -test -c /etc/xray/config.json >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] Xray configuration test failed!"
    exit 1
}

/usr/local/bin/envoy --mode validate -c /etc/envoy/envoy.yaml >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] Envoy configuration test failed!"
    exit 1
}

haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] HAProxy configuration test failed!"
    exit 1
}

apachectl -t >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] Apache configuration test failed!"
    exit 1
}

/usr/local/openresty/bin/openresty -t -c /etc/openresty/nginx.conf >/dev/null 2>&1 || {
    echo "[ENTRYPOINT ERROR] OpenResty configuration test failed!"
    exit 1
}

echo "[ENTRYPOINT] All service configurations validated successfully!"

# Hand off execution to Tini / Supervisord
exec "$@"
