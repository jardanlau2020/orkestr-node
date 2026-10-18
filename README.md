# edge-gateway

Minimal container image: a static status page on `/`, plus a private reverse-proxy
path in front of a local upstream process. Optional outbound tunnel included.

## Layout

| File | Purpose |
|---|---|
| `Dockerfile` | nginx + upstream binary, single process tree |
| `entrypoint.sh` | renders runtime configs from env, starts upstream + nginx |
| `www/index.html` | static landing page |

## Configuration

Everything is environment-driven; nothing is baked into the image.

| Variable | Default | Notes |
|---|---|---|
| `PORT` | `8080` | primary listen port; `8080` is always bound as well |
| `UPSTREAM_PATH` | random | private path routed to the upstream |
| `UPSTREAM_ID` | random | credential presented by the upstream listener |
| `TRANSPORT` | `ws` | `ws` or `xhttp` |
| `TUNNEL` | `none` | `none` or `argo` |
| `TUNNEL_TOKEN` | – | only used when `TUNNEL=argo` |
| `TUNNEL_PROTOCOL` | `http2` | tunnel edge transport |
| `DIAG_KEY` | – | enables `GET /__diag_<key>` |

Set `UPSTREAM_PATH` and `UPSTREAM_ID` explicitly in production. If left unset they are
regenerated on every start, and any client configured against the previous values breaks.

## Endpoints

- `GET /` — static page
- `GET /healthz` — `200 ok`, suitable for platform health probes
- `GET /__diag_<DIAG_KEY>` — read-only JSON with the active runtime parameters

## Runtime notes

- Configs are written under `/tmp`; `/etc` may be read-only in the target environment.
- nginx workers run on the same uid as the master, so temp directories need no
  ownership change (some sandboxes do not permit one).
- The upstream process is supervised and restarted on exit.
- The outbound connectivity probe runs in the background and never delays startup.

## Build and run

```bash
docker build -t edge-gateway .
docker run -p 8080:8080 \
  -e UPSTREAM_PATH=change-me \
  -e UPSTREAM_ID=00000000-0000-0000-0000-000000000000 \
  edge-gateway
```
