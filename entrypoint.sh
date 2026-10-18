#!/bin/sh
set -eu

PORT="${PORT:-8080}"
NODE_NAME="${NODE_NAME:-edge-01}"
TRANSPORT="${TRANSPORT:-ws}"        # ws | xhttp
TUNNEL="${TUNNEL:-none}"            # none | argo
XPORT=10000

UPSTREAM_PATH="${UPSTREAM_PATH:-$(head -c 9 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
UPSTREAM_PATH="${UPSTREAM_PATH#/}"
if [ -z "${UPSTREAM_ID:-}" ]; then
  if [ -r /proc/sys/kernel/random/uuid ]; then
    UPSTREAM_ID="$(cat /proc/sys/kernel/random/uuid)"
  else
    UPSTREAM_ID="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n' \
      | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
  fi
fi

echo "[init] port=${PORT} transport=${TRANSPORT} tunnel=${TUNNEL} path=/${UPSTREAM_PATH}"

# Outbound connectivity probe. Runs in background so it never delays startup.
( EGRESS="fail"
  if curl -m 2 -fsS -o /dev/null https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null; then
    EGRESS="ok"
  fi
  echo "[net] egress to cloudflare: ${EGRESS}" ) &

EGRESS="pending"

# Optional read-only diagnostics endpoint; disabled unless DIAG_KEY is set.
DIAG_LOC=""
if [ -n "${DIAG_KEY:-}" ]; then
  DIAG_LOC="        location = /__diag_${DIAG_KEY} {
            default_type application/json;
            return 200 '{\"transport\":\"${TRANSPORT}\",\"tunnel\":\"${TUNNEL}\",\"path\":\"/${UPSTREAM_PATH}\",\"id\":\"${UPSTREAM_ID}\",\"port\":${PORT},\"egress\":\"${EGRESS}\"}';
        }"
fi

# ---------------------------------------------------------------------------
# Reverse proxy location blocks
# ---------------------------------------------------------------------------
if [ "${TRANSPORT}" = "xhttp" ]; then
  LOC=$(cat <<'EOL'
        location = /__WS_PATH__ {
            proxy_pass              http://127.0.0.1:10000;
            proxy_http_version      1.1;
            proxy_set_header        Host              $host;
            proxy_set_header        X-Real-IP         $remote_addr;
            proxy_set_header        X-Forwarded-Proto $scheme;
            proxy_buffering         off;
            proxy_request_buffering off;
            proxy_read_timeout      3600s;
            proxy_send_timeout      3600s;
            chunked_transfer_encoding on;
        }
EOL
)
else
  LOC=$(cat <<'EOL'
        location = /__WS_PATH__ {
            if ($http_upgrade != "websocket") { return 404; }
            proxy_pass               http://127.0.0.1:10000;
            proxy_http_version       1.1;
            proxy_set_header         Upgrade                $http_upgrade;
            proxy_set_header         Connection             "upgrade";
            proxy_set_header         Sec-WebSocket-Protocol $http_sec_websocket_protocol;
            proxy_set_header         Sec-WebSocket-Extensions $http_sec_websocket_extensions;
            proxy_set_header         Host                   $host;
            proxy_set_header         X-Real-IP              $remote_addr;
            proxy_set_header         X-Forwarded-Proto      $scheme;
            proxy_buffering          off;
            proxy_request_buffering  off;
            proxy_read_timeout       3600s;
            proxy_send_timeout       3600s;
        }
EOL
)
fi

# Listen on both 8080 and $PORT so the health probe reaches us either way.
LISTEN="        listen      ${PORT} default_server;"
if [ "${PORT}" != "8080" ]; then
  LISTEN="${LISTEN}
        listen      8080;"
fi

{
cat <<EOF
# Keep workers on the master uid: temp dirs then need no ownership change.
user root;
worker_processes auto;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 4096; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    tcp_nopush    on;
    keepalive_timeout 3600s;
    server_tokens off;
    access_log    off;
    error_log     /dev/stderr warn;

    # Temp files under /tmp; /var may not be writable.
    client_body_temp_path /tmp/ngx-client;
    proxy_temp_path       /tmp/ngx-proxy;
    fastcgi_temp_path     /tmp/ngx-fcgi;
    uwsgi_temp_path       /tmp/ngx-uwsgi;
    scgi_temp_path        /tmp/ngx-scgi;

    server {
${LISTEN}
        server_name _;
        root        /www;
        index       index.html;

        # Health probe target
        location = /healthz { return 200 'ok'; }
EOF
printf '%s\n' "${LOC}" | sed "s|__WS_PATH__|${UPSTREAM_PATH}|g"
if [ -n "${DIAG_LOC}" ]; then
  printf '%s\n' "${DIAG_LOC}"
fi
cat <<'EOF'
        location / { try_files $uri $uri/ /index.html; }
    }
}
EOF
} > /tmp/nginx.conf
# Runtime configs live in /tmp; /etc may be read-only.

# ---------------------------------------------------------------------------
# Upstream service config
# ---------------------------------------------------------------------------
if [ "${TRANSPORT}" = "xhttp" ]; then
  STREAM=$(cat <<'EOL'
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "/__WS_PATH__",
          "mode": "auto"
        }
EOL
)
else
  STREAM=$(cat <<'EOL'
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "/__WS_PATH__",
          "maxEarlyData": 2048,
          "earlyDataHeaderName": "Sec-WebSocket-Protocol"
        }
EOL
)
fi

{
cat <<EOF
{
  "log": { "loglevel": "warning", "access": "none" },
  "inbounds": [
    {
      "tag": "in",
      "listen": "127.0.0.1",
      "port": ${XPORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UPSTREAM_ID}", "level": 0, "email": "node" } ],
        "decryption": "none"
      },
      "streamSettings": {
EOF
printf '%s\n' "${STREAM}" | sed "s|__WS_PATH__|${UPSTREAM_PATH}|g"
cat <<'EOF'
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "AsIs" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
} > /tmp/xray.json

if [ -f /www/index.html ] && [ -w /www/index.html ]; then
  sed -e "s|__NODE_NAME__|${NODE_NAME}|g" /www/index.html > /tmp/i.html && mv /tmp/i.html /www/index.html
fi

# Fail fast if config generation did not produce files.
if [ ! -s /tmp/nginx.conf ] || [ ! -s /tmp/xray.json ]; then
  echo "[FATAL] config generation failed: /tmp not writable?"
  exit 1
fi

if ! /usr/local/bin/xray run -test -c /tmp/xray.json >/tmp/xray-test.log 2>&1; then
  echo "[FATAL] upstream config invalid:"
  cat /tmp/xray-test.log
fi

# Keep the startup banner minimal: container stdout is captured by the platform.
echo "[ready] transport=${TRANSPORT} tunnel=${TUNNEL} upstream=127.0.0.1:${XPORT}"

(
  while true; do
    /usr/local/bin/xray run -c /tmp/xray.json 2>&1
    echo "[supervisor] upstream exited, restart in 3s"
    sleep 3
  done
) &

# ---------------------------------------------------------------------------
# Optional outbound tunnel
# ---------------------------------------------------------------------------
if [ "${TUNNEL}" = "argo" ]; then
  CF_PROTO="${TUNNEL_PROTOCOL:-http2}"
  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    echo "[tunnel] named tunnel, protocol=${CF_PROTO}, origin=http://localhost:8080"
    # Pass the token via the environment rather than argv.
    export TUNNEL_TOKEN
    cloudflared tunnel --no-autoupdate --protocol "${CF_PROTO}" --loglevel info run 2>&1 &
  else
    echo "[tunnel] quick tunnel, protocol=${CF_PROTO}, url in log"
    cloudflared tunnel --no-autoupdate --protocol "${CF_PROTO}" --loglevel info \
      --url "http://127.0.0.1:8080" 2>&1 &
  fi
fi

exec nginx -c /tmp/nginx.conf -g 'daemon off;'
