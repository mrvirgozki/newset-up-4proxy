FROM envoyproxy/envoy:v1.39.1 AS envoy
FROM ghcr.io/xtls/xray-core:25.12.8 AS xray
FROM openresty/openresty:1.31.1.1-bookworm-fat

ENV DEBIAN_FRONTEND=noninteractive

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray
ENV XRAY_LOCATION_CONFIG=/etc/xray

ENV BIND_ADDR=0.0.0.0

ENV HAPROXY_PORT=8081
ENV OPENRESTY_PORT=8082
ENV APACHE_PORT=8083

ENV HAPROXY_GRPC_PORT=8084
ENV OPENRESTY_GRPC_PORT=8085

WORKDIR /opt/virgozki

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apache2 \
        apache2-utils \
        haproxy \
        python3 \
        ca-certificates \
        curl \
        wget \
        unzip \
        tini \
        procps \
        iproute2 \
        net-tools \
        openssl && \
    a2enmod \
        proxy \
        proxy_http \
        proxy_http2 \
        proxy_wstunnel \
        headers \
        rewrite \
        http2 && \
    mkdir -p \
        /var/lib/haproxy \
        /run/haproxy \
        /var/run/haproxy \
        /run/apache2 \
        /var/run/apache2 \
        /etc/xray \
        /etc/haproxy \
        /etc/envoy \
        /tmp/virgozki \
        /tmp/virgozki-logs \
        /var/log/xray \
        /usr/share/nginx/html && \
    chown -R haproxy:haproxy \
        /var/lib/haproxy \
        /run/haproxy \
        /var/run/haproxy && \
    chmod 777 \
        /tmp/virgozki \
        /tmp/virgozki-logs \
        /run/apache2 \
        /var/run/apache2 \
        /var/run/haproxy && \
    rm -rf \
        /var/lib/apt/lists/* \
        /var/tmp/*

COPY --from=envoy /usr/local/bin/envoy /usr/local/bin/envoy

COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY --from=xray /usr/local/share/xray /usr/local/share/xray

RUN mkdir -p \
        /etc/xray \
        /etc/haproxy \
        /etc/envoy \
        /etc/apache2/conf-available \
        /etc/apache2/conf-enabled \
        /var/log/xray \
        /var/log/apache2 \
        /var/lock/apache2 \
        /var/run/apache2 \
        /tmp/virgozki \
        /tmp/virgozki-logs \
        /usr/share/nginx/html && \
    chmod 755 \
        /etc/xray \
        /etc/haproxy \
        /etc/envoy

COPY config.json /etc/xray/config.json
COPY nginx.conf /etc/openresty/nginx.conf
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY httpd.conf /etc/apache2/conf-available/virgozki.conf
COPY index.html /usr/share/nginx/html/index.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN a2enconf virgozki

RUN chmod +x /usr/local/bin/entrypoint.sh && \
    chmod 644 \
        /etc/xray/config.json \
        /etc/openresty/nginx.conf \
        /etc/haproxy/haproxy.cfg \
        /etc/apache2/conf-available/virgozki.conf && \
    chmod -R 755 /usr/share/nginx/html

EXPOSE 8080

STOPSIGNAL SIGTERM

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/usr/local/bin/entrypoint.sh"]
