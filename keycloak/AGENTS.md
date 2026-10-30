# keycloak/

Identity provider (OIDC / SAML / LDAP). Two containers: `keycloak` (UI, admin
console, `/realms/...`) and `postgresql` on a private bridge; `keycloak` also joins
`npm-net` so NPM can proxy it.

```
docker-compose.yml   house style applied to the official image + its own postgres
providers/           custom provider JARs, mounted read-only at /opt/keycloak/providers
themes/              custom themes, mounted read-only at /opt/keycloak/themes
postgresql/          runtime state (untracked) -- this IS the instance
```

Independent of `authentik/`: separate database, network, container names. Both may run;
no client should be configured for both.

## Traps

- **Health is on `:9000`, not `:8080`.** Turning on `KC_HEALTH_ENABLED` moves `/health*`
  to Keycloak's management interface. A probe against the main port 404s and pins the
  container unhealthy while it is serving fine.
- **The image contains no HTTP client.** ubi9-micro ships `bash`, `java` and `keytool`
  only -- no `curl`, `wget`, `nc` or `busybox`. The healthcheck is upstream's documented
  bash `/dev/tcp` redirect, with `CMD-SHELL` relying on `/bin/sh` being bash. Do not
  "simplify" it to `curl -f`.
- **`start`, never `start-dev`, and not `--optimized` yet.** `health-enabled` is a
  *build-time* option and this image carries no prebuilt configuration, so `start` runs
  the build on every boot (~20-40s, covered by `start_period: 180s`). Switching to
  `--optimized` without baking a build into an image silently removes the health
  endpoints.
- **No `./data` mount, on purpose.** Keycloak writes its build output and transaction
  logs to `/opt/keycloak/data` inside the image, as uid 1000. Docker creates mount
  sources as root, so binding a host dir there makes those writes fail and the container
  crash-loops. All real state is in postgres.
- **`providers/` and `themes/` are mounted read-only.** Keycloak consumes them during the
  start-time build and never writes back; a root-owned, writable mount is an EACCES
  waiting to happen. To add a provider: drop the JAR in `providers/`, then
  `docker compose restart keycloak` (the restart rebuilds).
- **Bootstrap admin options apply only when the master realm is absent**, i.e. against an
  empty database. Later starts ignore them, so a UI password change is permanent -- but
  dropping the variables means a rebuilt database comes up with no admin. Recovery is
  `kc.sh bootstrap-admin user`, which needs all nodes stopped.
- **`KC_HOSTNAME` is the OIDC issuer.** It must match the browser-visible URL exactly,
  scheme included. Changing it invalidates issued tokens; set it before creating clients.
- **The image runs as uid 1000 with no capabilities.** Do not add `cap_add`.
- NPM proxies `keycloak:8080` over `npm-net`, with Websockets Support on. Never publish
  or proxy `:9000` -- that is the management interface (`/health`, `/metrics`).

## Setup order

1. `cp .env.example .env`, replace every `changeme`, `docker compose up -d`.
2. Add the NPM Proxy Host for `KEYCLOAK_HOSTNAME` -> `keycloak:8080` (websockets on).
3. Log in at `/admin` with the bootstrap admin.
4. Create the realm before any client, so the issuer in issued tokens already matches the
   URL clients will be configured with.

Realm import: copy the file in and run `kc.sh import` inside the container
(`docker compose cp realm.json keycloak:/tmp/` then
`docker compose exec keycloak /opt/keycloak/bin/kc.sh import --file /tmp/realm.json`).
Do not add `--import-realm` to the command line together with a `./data` mount -- see the
data-dir trap above.

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```
