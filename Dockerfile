# Edge gateway: reverse proxy in front of a local service, optional outbound tunnel
FROM nginx:1.27-alpine

ARG XRAY_VER=25.9.11
ARG TARGETARCH

RUN apk add --no-cache curl unzip ca-certificates tzdata \
 && case "${TARGETARCH:-amd64}" in \
      amd64) XZIP="Xray-linux-64.zip";          CFB="cloudflared-linux-amd64" ;; \
      arm64) XZIP="Xray-linux-arm64-v8a.zip";   CFB="cloudflared-linux-arm64" ;; \
      *)     XZIP="Xray-linux-64.zip";          CFB="cloudflared-linux-amd64" ;; \
    esac \
 && curl -fsSL -o /tmp/x.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/${XZIP}" \
 && unzip -q /tmp/x.zip -d /usr/local/bin \
 && chmod +x /usr/local/bin/xray \
 && rm -f /tmp/x.zip \
 && curl -fsSL -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/${CFB}" \
 && chmod +x /usr/local/bin/cloudflared \
 && mkdir -p /etc/xray /www

COPY entrypoint.sh /entrypoint.sh
COPY www/          /www/

RUN mkdir -p /tmp/ngx-client /tmp/ngx-proxy /tmp/ngx-fcgi /tmp/ngx-uwsgi /tmp/ngx-scgi \
 && chmod -R 777 /tmp/ngx-client /tmp/ngx-proxy /tmp/ngx-fcgi /tmp/ngx-uwsgi /tmp/ngx-scgi /www \
 && chmod +x /entrypoint.sh

ENV PORT=8080 \
    UPSTREAM_PATH="" \
    UPSTREAM_ID="" \
    NODE_NAME="edge-01" \
    TRANSPORT="ws" \
    TUNNEL="none" \
    TUNNEL_TOKEN="" \
    TUNNEL_PROTOCOL="http2"

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
