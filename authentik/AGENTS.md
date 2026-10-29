# authentik/

Identity provider (SSO / OIDC / LDAP / forward auth). Three containers:
`server` (UI + API + outpost endpoints), `worker` (background tasks), `postgresql`.

```
docker-compose.yml      house style applied to upstream's compose.yml
authentik-nginx.conf    paste into NPM Proxy Host -> Advanced (see below)
custom-templates/       mounted at /templates, optional overrides (untracked ok)
data/ certs/ postgresql/  runtime state, never commit
```

## Traps

- **No `/etc/localtime` or `/etc/timezone` mount, on purpose.** Authentik does all
  internal work in UTC and localizes for display; mounting the host zone breaks OAuth and
  SAML auth. Every other service here mounts them — do not "restore consistency".
- **Healthcheck must be `ak healthcheck`.** The image's entrypoint dispatches
  `healthcheck` but has no `health` case, so `ak health` falls through to a management
  command that does not exist and the container pins unhealthy forever while serving fine.
- **`start_period: 300s` is not padding.** First boot runs every migration plus the setup
  flow.
- **No redis service**, intentionally: cache and task queue fall back to postgres.
- **No proxy service**, intentionally: `server` serves UI, `/api/` and `/application/o/`
  itself on `:9000`. NPM points at `authentik-server:9000` over `npm-net`.
- **9443 is commented out.** cloudflared already terminates TLS; a second cert is a second
  renewal for a hop that never leaves the host.
- **`shm_size: 512mb`** because Django's threaded workers use `/dev/shm`; the 64MB default
  silently falls back to disk-backed storage and a busy instance crawls.
- **Worker's `docker.sock` and `user: root` are commented out.** They are only needed to
  manage an embedded outpost container. Nothing else touches the socket.
- **`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` must be the real `npm-net` subnet**, not the
  shipped RFC1918 defaults. Get it with
  `docker network inspect npm-net --format '{{ .IPAM.Config[0].Subnet }}'`. Without it
  authentik discards `X-Forwarded-Proto` and emits `http://` URLs.

## NPM custom config

`authentik-nginx.conf` replaces NPM's generated default `location /`, so it does the
proxying itself (`include conf.d/include/proxy.conf`). It hardcodes
`X-Forwarded-Proto https` because the tunnel reaches NPM over plain HTTP and the browser
would otherwise block mixed content. If the snippet fails nginx's config test, NPM deletes
the vhost and the domain falls through to the stock welcome page — a welcome page means
this file broke, not that authentik is down.

## Setup order

1. `cp .env.example .env`, fill every `changeme`, `docker compose up -d`.
2. Open `/if/flow/initial-setup/` once, then blank `AUTHENTIK_BOOTSTRAP_PASSWORD`.
3. Set the authentik URL (e.g. `https://auth.example.com/`) **before** creating any OAuth
   provider, or the issuer claim will not match what clients expect.

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```
