#!/bin/sh
set -eu

PORT="${PORT:-8080}"
XRAY_PID=""
PIDS=""

cleanup() {
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  [ -n "$XRAY_PID" ] && kill "$XRAY_PID" 2>/dev/null || true
}
trap cleanup INT TERM EXIT

echo "== VIRGOZKI 4-PROXY + gRPC =="
echo "Public port: $PORT"

echo "Engines: OpenResty / HAProxy / Envoy / Apache httpd"

wait_port() {
  host="$1"; port="$2"; name="$3"
  i=0
  while [ "$i" -lt 50 ]; do
    if python3 - "$host" "$port" <<'PY' >/dev/null 2>&1
import socket, sys
s=socket.socket(); s.settimeout(0.5)
s.connect((sys.argv[1], int(sys.argv[2])))
s.close()
PY
    then echo "$name ready on $host:$port"; return 0; fi
    i=$((i+1)); sleep 0.2
  done
  echo "ERROR: $name did not become ready"; return 1
}

start_bg() {
  "$@" &
  p=$!
  PIDS="$PIDS $p"
}

write_haproxy() {
cat > /tmp/haproxy.cfg <<'HAP'
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
    http-request set-header X-Forwarded-Proto https
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
    http-request return status 404 content-type text/plain lf-string "not found\n"

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
HAP
}

write_envoy_engine() {
cat > /tmp/envoy-engine.yaml <<'EOFY'
static_resources:
  listeners:
  - name: engine
    address: { socket_address: { address: 127.0.0.1, port_value: 8300 } }
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
            name: routes
            virtual_hosts:
            - name: all
              domains: ["*"]
              routes:
              - match: { prefix: "/virgozki" }
                route: { cluster: trojan_http, timeout: 0s }
              - match: { prefix: "/vmess-virgozki" }
                route: { cluster: vmess_http, timeout: 0s }
              - match: { prefix: "/vless-virgozki" }
                route: { cluster: vless_http, timeout: 0s }
              - match: { prefix: "/ss-virgozki" }
                route: { cluster: ss_http, timeout: 0s }
              - match: { prefix: "/trojan-grpc" }
                route: { cluster: trojan_grpc, timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/vmess-grpc" }
                route: { cluster: vmess_grpc, timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/vless-grpc" }
                route: { cluster: vless_grpc, timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/ss-grpc" }
                route: { cluster: ss_grpc, timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/" }
                direct_response: { status: 404 }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: trojan_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: trojan_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10000 } } } }] }] }
  - name: vmess_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: vmess_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10004 } } } }] }] }
  - name: vless_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: vless_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10008 } } } }] }] }
  - name: ss_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: ss_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10012 } } } }] }] }
  - name: trojan_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: trojan_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10003 } } } }] }] }
  - name: vmess_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: vmess_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10007 } } } }] }] }
  - name: vless_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: vless_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10011 } } } }] }] }
  - name: ss_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: ss_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 10015 } } } }] }] }
admin: { address: { socket_address: { address: 127.0.0.1, port_value: 9902 } } }
EOFY
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
    ProxyPass "/trojan-grpc" "h2c://127.0.0.1:10003" connectiontimeout=3 timeout=3600
    ProxyPass "/vmess-grpc" "h2c://127.0.0.1:10007" connectiontimeout=3 timeout=3600
    ProxyPass "/vless-grpc" "h2c://127.0.0.1:10011" connectiontimeout=3 timeout=3600
    ProxyPass "/ss-grpc" "h2c://127.0.0.1:10015" connectiontimeout=3 timeout=3600
    ProxyPass "/virgozki" "http://127.0.0.1:10000" connectiontimeout=3 timeout=3600 upgrade=websocket
    ProxyPass "/virgozki-hu" "http://127.0.0.1:10001" connectiontimeout=3 timeout=3600
    ProxyPass "/virgozki-xhttp" "http://127.0.0.1:10002" connectiontimeout=3 timeout=3600
    ProxyPass "/vmess-virgozki" "http://127.0.0.1:10004" connectiontimeout=3 timeout=3600 upgrade=websocket
    ProxyPass "/vmess-virgozki-hu" "http://127.0.0.1:10005" connectiontimeout=3 timeout=3600
    ProxyPass "/vmess-virgozki-xhttp" "http://127.0.0.1:10006" connectiontimeout=3 timeout=3600
    ProxyPass "/vless-virgozki" "http://127.0.0.1:10008" connectiontimeout=3 timeout=3600 upgrade=websocket
    ProxyPass "/vless-virgozki-hu" "http://127.0.0.1:10009" connectiontimeout=3 timeout=3600
    ProxyPass "/vless-virgozki-xhttp" "http://127.0.0.1:10010" connectiontimeout=3 timeout=3600
    ProxyPass "/ss-virgozki" "http://127.0.0.1:10012" connectiontimeout=3 timeout=3600 upgrade=websocket
    ProxyPass "/ss-virgozki-hu" "http://127.0.0.1:10013" connectiontimeout=3 timeout=3600
    ProxyPass "/ss-virgozki-xhttp" "http://127.0.0.1:10014" connectiontimeout=3 timeout=3600
</VirtualHost>
APACHE
}

write_front() {
cat > /tmp/envoy-front.yaml <<EOFY
static_resources:
  listeners:
  - name: public
    address: { socket_address: { address: 0.0.0.0, port_value: ${PORT} } }
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
            name: routes
            virtual_hosts:
            - name: all
              domains: ["*"]
              routes:
              - match: { prefix: "/openresty/trojan-grpc" }
                route: { cluster: openresty_grpc, prefix_rewrite: "/trojan-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/openresty/vmess-grpc" }
                route: { cluster: openresty_grpc, prefix_rewrite: "/vmess-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/openresty/vless-grpc" }
                route: { cluster: openresty_grpc, prefix_rewrite: "/vless-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/openresty/ss-grpc" }
                route: { cluster: openresty_grpc, prefix_rewrite: "/ss-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/openresty/" }
                route: { cluster: openresty_http, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/haproxy/trojan-grpc" }
                route: { cluster: haproxy_grpc, prefix_rewrite: "/trojan-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/haproxy/vmess-grpc" }
                route: { cluster: haproxy_grpc, prefix_rewrite: "/vmess-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/haproxy/vless-grpc" }
                route: { cluster: haproxy_grpc, prefix_rewrite: "/vless-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/haproxy/ss-grpc" }
                route: { cluster: haproxy_grpc, prefix_rewrite: "/ss-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/haproxy/" }
                route: { cluster: haproxy_http, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/envoy/trojan-grpc" }
                route: { cluster: envoy_grpc, prefix_rewrite: "/trojan-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/envoy/vmess-grpc" }
                route: { cluster: envoy_grpc, prefix_rewrite: "/vmess-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/envoy/vless-grpc" }
                route: { cluster: envoy_grpc, prefix_rewrite: "/vless-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/envoy/ss-grpc" }
                route: { cluster: envoy_grpc, prefix_rewrite: "/ss-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/envoy/" }
                route: { cluster: envoy_http, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/apache/trojan-grpc" }
                route: { cluster: apache_grpc, prefix_rewrite: "/trojan-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/apache/vmess-grpc" }
                route: { cluster: apache_grpc, prefix_rewrite: "/vmess-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/apache/vless-grpc" }
                route: { cluster: apache_grpc, prefix_rewrite: "/vless-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/apache/ss-grpc" }
                route: { cluster: apache_grpc, prefix_rewrite: "/ss-grpc", timeout: 0s, max_stream_duration: { grpc_timeout_header_max: 0s } }
              - match: { prefix: "/apache/" }
                route: { cluster: apache_http, prefix_rewrite: "/", timeout: 0s }
              - match: { prefix: "/" }
                route: { cluster: openresty_http, prefix_rewrite: "/", timeout: 0s }
          http_filters:
          - name: envoy.filters.http.local_ratelimit
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.local_ratelimit.v3.LocalRateLimit
              stat_prefix: public_limit
              token_bucket: { max_tokens: 600, tokens_per_fill: 300, fill_interval: 1s }
              filter_enabled: { default_value: { numerator: 100, denominator: HUNDRED } }
              filter_enforced: { default_value: { numerator: 100, denominator: HUNDRED } }
          - name: envoy.filters.http.router
            typed_config: { "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router }
  clusters:
  - name: openresty_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: openresty_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8101 } } } }] }] }
  - name: openresty_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: openresty_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8102 } } } }] }] }
  - name: haproxy_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: haproxy_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8201 } } } }] }] }
  - name: haproxy_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: haproxy_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8202 } } } }] }] }
  - name: envoy_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: envoy_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8300 } } } }] }] }
  - name: envoy_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: envoy_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8300 } } } }] }] }
  - name: apache_http
    type: STATIC
    connect_timeout: 3s
    load_assignment: { cluster_name: apache_http, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8400 } } } }] }] }
  - name: apache_grpc
    type: STATIC
    connect_timeout: 3s
    http2_protocol_options: {}
    load_assignment: { cluster_name: apache_grpc, endpoints: [{ lb_endpoints: [{ endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8400 } } } }] }] }
admin: { address: { socket_address: { address: 127.0.0.1, port_value: 9901 } } }
EOFY
}

echo "[1/5] Validating Xray config..."
xray run -test -c /etc/xray.json

echo "[2/5] Starting Xray..."
xray run -c /etc/xray.json >/tmp/xray.log 2>&1 &
XRAY_PID=$!
sleep 2
kill -0 "$XRAY_PID" 2>/dev/null || { cat /tmp/xray.log; exit 1; }

# OpenResty
openresty -t -c /usr/local/openresty/nginx/conf/nginx.conf
openresty -g 'daemon off;' -c /usr/local/openresty/nginx/conf/nginx.conf >/tmp/openresty.log 2>&1 &
PIDS="$PIDS $!"
wait_port 127.0.0.1 8101 "OpenResty HTTP"
wait_port 127.0.0.1 8102 "OpenResty gRPC"

# HAProxy
write_haproxy
haproxy -c -f /tmp/haproxy.cfg
haproxy -W -db -f /tmp/haproxy.cfg >/tmp/haproxy.log 2>&1 &
PIDS="$PIDS $!"
wait_port 127.0.0.1 8201 "HAProxy HTTP"
wait_port 127.0.0.1 8202 "HAProxy gRPC"

# Envoy engine
write_envoy_engine
envoy -c /tmp/envoy-engine.yaml --log-level warning >/tmp/envoy-engine.log 2>&1 &
PIDS="$PIDS $!"
wait_port 127.0.0.1 8300 "Envoy engine"

# Apache
write_apache
apache2 -t -f /tmp/apache-xray.conf
apache2 -DFOREGROUND -f /tmp/apache-xray.conf >/tmp/apache.log 2>&1 &
PIDS="$PIDS $!"
wait_port 127.0.0.1 8400 "Apache httpd"

echo "[5/5] Starting public Envoy selector..."
write_front
exec envoy -c /tmp/envoy-front.yaml --log-level warning
