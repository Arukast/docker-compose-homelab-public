# AGENTS.md

A fleet of independent Docker Compose stacks for a self-hosted homelab. **There is no
root compose file.** Every top-level directory is its own compose project, deployed on
its own. "The repo" is the collection, not a single stack.

Read this file before editing anything. Per-directory `AGENTS.md` files carry
service-specific traps — check for one when you enter a directory.

## Layout

```
<service>/docker-compose.yml   one project per directory, self-contained
<service>/.env.example         committed; documents every variable + network bootstrap
<service>/.env                 untracked (ignored by the `.env` rule); required on hosts
<service>/<config files>       mounted read-only into the container
<service>/<data dirs>          runtime state, untracked, never committed
setup-target.sh                one-time host provisioning (see below)
.github/workflows/deploy.yml   CI: deploy changed directories, mirror to public repo
```

`npm` is the internal reverse-proxy router (LAN and cloudflared entry). `npm-front` is the
public-IP TLS edge that fronts `anubis`. Both are nginx-proxy-manager and both run on the
same edge host, where `npm-front` owns host 80/443 and `npm` moves to
`NPM_HTTP_PORT`/`NPM_HTTPS_PORT`. They are different services, not duplicates.

## Deploy pipeline (this drives most of the repo's constraints)

1. Push to `main` on `Arukast/docker-compose-homelab` → self-hosted runner.
2. CI diffs the push, takes the **first path segment** of every changed file, drops
   dot-directories, and deploys only those directories. Root-level files
   (`setup-target.sh`, `LICENSE`, `.github/**`) trigger **no deploy**.
3. For each directory it SSHes to every host listed for that name in
   `/etc/homelab/hosts.env` on the runner, using a restricted key whose forced command
   runs `deploy-service.sh <dir>`:
   `git pull origin main && docker compose pull && docker compose up -d --build --remove-orphans`
   then prunes images and build cache older than 24h.
4. `sync-to-public` force-pushes `main` to the public mirror.

Consequences you must respect:

- **Directory name is the deployment key.** Renaming a directory silently stops its
  deploys unless `hosts.env` and the hosts' sparse checkouts are updated too.
- Hosts use `git sparse-checkout`, so **only some directories exist on any given host**.
  A cross-directory reference (e.g. `crowdsec` mounting `../npm-front/.../logs`) only
  works when both are checked out on that host. Don't add cross-directory mounts casually.
- A new directory needs host-side setup (`setup-target.sh <dirs> <repo> <key>`) and a
  hand-created `.env`; CI cannot bootstrap either.
- Deploys run `compose up -d --build --remove-orphans`: a stack that needs something not
  in its own directory will fail on the host, not in review.

## House style for compose files

Every service in this repo follows the same shape. Match it; don't "simplify" it.

```yaml
x-logging: &default-logging        # when the file already defines it
  logging:
    driver: json-file
    options: { max-size: "10m", max-file: "3" }

services:
  thing:
    image: repo/image:1.2.3@sha256:...   # tag AND digest, always
    container_name: ${THING_CONTAINER_NAME:-thing}
    restart: unless-stopped
    security_opt: [no-new-privileges:true]
    <<: *default-logging
    ports: ["${HOST_IP:-127.0.0.1}:8080:8080"]
    healthcheck: { ... }                 # a real, existing endpoint
    cap_drop: [ALL]
    cap_add: [ ... ]                     # only what the image truly needs
    deploy:
      resources:
        limits: { memory: 512m, cpus: "1.0" }
```

Rules that are enforced by convention here, not by tooling:

- **Images are pinned by tag + `@sha256:` digest.** Renovate
  (`.github/renovate.json`, `pinDigests: true`) owns bumps — take its PRs rather than
  hand-editing digests. If you bump by hand, update tag and digest together.
- **`cap_drop: ALL` first, then a minimal `cap_add`.** Most root-then-drop images need
  `CHOWN`, `SETUID`, `SETGID`; postgres-family entrypoints additionally need
  `DAC_OVERRIDE`, `FOWNER`; anything binding a privileged port in-container needs
  `NET_BIND_SERVICE`; daemons that signal dropped-privilege children need `KILL`.
  Dropping caps without the matching adds makes entrypoints abort under `set -e` and
  restart-loop. See `presidio`, `stirling-pdf`, `snapotter` for the archetypes.
- **`DAC_OVERRIDE`/`FOWNER` are usually there for a reason.** `--build` + older
  `setup-target.sh` left bind-mounted data dirs deployer-owned, so root containers need
  these to write them. Don't strip them as "unnecessary".
- **Host ports bind to `${HOST_IP:-127.0.0.1}`.** Loopback is the default posture. The
  only deliberate all-interface binds are `npm-front` 80/443 and `npm`'s 80/443 defaults.
  Don't publish `0.0.0.0`.
- **Services get a `healthcheck`** against an endpoint that actually exists on that image
  (`/openapi.json` for rembg, `ak healthcheck` for authentik), and a `start_period` long
  enough for real boot (models: 300s, JVM: 120s). A few images ship their own HEALTHCHECK
  instead; don't invent an endpoint for those.
- **Every service gets `deploy.resources.limits`** (`memory`, `cpus`) with a comment
  saying where the number comes from. These are backstops, not budgets.
- **Bind-mount state under the service directory**, so it is visible to backup tooling.
  Named volumes are the exception, used when the deployer must not need write access to
  the checkout (`embedder/tei-model`, `rembg/rembg-models`, `portainer_data`).
- **Shared networks are `external: true`** with a comment naming who else is on them and
  the `docker network create` line. The full inventory lives below.
- Tune Docker only as needed: `read_only: true` + `tmpfs: [/tmp]` for stateless images,
  `shm_size` for Django/workers, `dns:` where the VCN resolver is unreachable (OCI).

## Networks (created by hand, once per host)

| Network | Kind | Members |
| --- | --- | --- |
| `npm-net` | external | `npm`, `cloudflared`, `uptime-kuma`, `anubis`, `npm-front`, `authentik`, `keycloak` |
| `cloudflared-net` | external | `cloudflared`, `npm` |
| `anubis-net` | external | `anubis`, `npm-front` |
| `ai-net` | external (has egress) | `omniroute`, `hermes`, `litellm-proxy`, `open-webui`, `searxng`, `rembg`, `embedder/model-fetch` |
| `shared-ai-backend-net` | external, created `--internal` | `litellm-proxy`, `omniroute/redis`, `open-webui`, `presidio-*`, `embedder/text-embeddings-inference` |
| `socket-proxy-net` | external | `socket-proxy` |

Ingress has two paths, and that is why there are two routers:

- **Tunnel path:** `cloudflared` → `npm:80` → service. Cloudflare is the only entry point,
  so these services need no Anubis challenge.
- **Public-IP path (edge host only):** internet → `npm-front` 80/443 (TLS) →
  `anubis:8923` (bot PoW) → `npm:80` → service. Anubis exists because nothing else protects
  this path; it is Host-agnostic, so one instance covers every site the router serves.

Both nginx-proxy-manager instances run on that host; `npm-front` owns 80/443 there, so
`npm`'s host ports become `NPM_HTTP_PORT`/`NPM_HTTPS_PORT` and `anubis` reaches it as
`npm:80` over `npm-net`.

AI traffic: `open-webui`/`hermes` → `litellm-proxy:4000` → `omniroute:20128` → upstream,
with Presidio guardrails on `shared-ai-backend-net`.

Services that must share the host network (and say so in a comment): `adguard`,
`glances`, `host-tailscale`, `crowdsec/crowdsec-firewall-bouncer`.

## Environment and secrets

- Each directory reads its own `.env`. **The root `.env` is not read by compose** (there
  is no root compose file) — treat it as the author's scratch file. Never move values
  into it.
- `.env.example` is the spec: every variable the compose file reads must appear there,
  with `HOST_IP=changeme`, a `changeme` placeholder for anything that must be replaced,
  and a header comment listing the `docker network create` commands the directory needs.
- Secrets use `${VAR:?message required}` so a missing value fails loudly instead of
  booting with an empty password. Generate with `openssl rand -hex 32`.
- Healthchecks that read container-side vars must escape them (`$${PG_PASS}`), or compose
  interpolates them from `.env` first and they expand to empty.
- Never commit `.env`, tokens, certs, or runtime data. `.gitignore` already covers them.

## Runtime data

Bind-mounted state (`*/data`, `*/config`, `*/logs`, `*/appdata`, `*/postgres`, keys, etc.)
is created by containers and is untracked. Two hard rules from `setup-target.sh`:

- **Never `chown -R` the checkout.** It walks into bind mounts, resets container-assigned
  ownership, and breaks stateful containers (notably `uptime-kuma`'s embedded MariaDB on
  uid 1000). Fix ownership of `.git` only, per path.
- Run git as the `deployer` user, not root.

Tracked exceptions: `openwebui/open-webui-data/functions/` (source, not state),
`crowdsec/crowdsec/acquis.d/`, `searxng/searxng-data/settings.yml`.

## Commenting

This repo's distinguishing feature: comments explain **why**, including which upstream
bug or failure mode a choice works around (see `authentik`, `embedder`, `presidio`).
When editing nearby code, preserve that reasoning. When adding a capability, port
binding, limit, or healthcheck, add the one-line justification. Do not add narration of
what the YAML already says.

## Validating a change

There is no test suite and CI only deploys. Validate locally:

```sh
# syntax + interpolation, per directory. HOST_IP=changeme in .env.example is not a
# valid IP, so override it; `level=warning ... variable is not set` lines are expected
# for the optional, commented-out vars. Only errors matter.
HOST_IP=127.0.0.1 docker compose --project-directory ./<dir> \
  --env-file ./<dir>/.env.example -f ./<dir>/docker-compose.yml config --quiet

# sanity-check port collisions and healthchecks without deploying
HOST_IP=127.0.0.1 docker compose ... config | grep -E 'published|test:'
```

Never `docker compose up` this repo on a workstation as a "test" — several stacks bind
host networking, the Docker socket, or privileged ports, and the AI stack assumes an
11 GB host. Show the diff and let the author deploy.

## Commits

Conventional-commit style as used here: `feat: ...`, `fix: ...`, `chore(deps): ...`
(Renovate). Scope-free, lowercase, imperative, describing the user-visible effect
(`fix: add DAC_OVERRIDE/FOWNER cap`, `feat: npm front and fix anubis`).
