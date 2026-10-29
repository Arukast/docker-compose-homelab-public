# docker-compose-homelab

A self-hosted homelab run as a fleet of independent Docker Compose stacks. Every
top-level directory is one stack, self-contained, with its own `docker-compose.yml`,
`.env.example`, config files and runtime state. **There is no root compose file** —
`docker compose` is always run from inside a stack directory.

That layout is deliberate: CI deploys each stack separately, and a host only checks out
the stacks assigned to it.

## Architecture

Services are published one of two ways, and that choice is the whole reason there are two
nginx-proxy-manager instances.

```
tunnel path -- Cloudflare-protected
  Internet ─► Cloudflare ─► cloudflared ─► npm :80 ─► service

public-IP path -- no tunnel, so it needs bot protection
  Internet ─► npm-front :80/443 ─► anubis :8923 ─► npm :80 ─► service
              (TLS edge)           (proof of work)   (router)
```

- **Tunnel path.** The hostname and route live in the Cloudflare tunnel config;
  `cloudflared` joins `npm-net` and forwards to `http://npm:80` by container name. Traffic
  never touches the host's public 80/443, and Cloudflare is the only entry point, so these
  services need no Anubis challenge.
- **Public-IP path.** The domain's DNS record at Cloudflare resolves to the host's public
  IP. `npm-front` terminates TLS (Let's Encrypt / wildcard certs), `anubis` challenges bots
  with proof of work, then `npm` routes by Host header. This path exists precisely because
  nothing else is protecting it.
- `npm` and `npm-front` are both nginx-proxy-manager and **both run on the same edge
  host**. There, `npm-front` owns the real host 80/443 and `npm` moves to
  `NPM_HTTP_PORT`/`NPM_HTTPS_PORT` (on `npm-net` it is still `npm:80`); their admin UIs sit
  on different host ports (81 and 82). Every other host runs only `npm`, on 80/443.
- `anubis` is one gateway covering every public-IP hostname — it is Host-agnostic, not a
  per-site component.
- `authentik` provides SSO/OIDC for the services that support it.

AI traffic flows separately:

```
open-webui ─┐
hermes ─────┴─► litellm-proxy :4000 ─► omniroute :20128 ─► upstream models
                         │
                         └─ presidio guardrails (PII mask) on shared-ai-backend-net

open-webui ─► searxng (web search), rembg (background removal)
embedder ──► text-embeddings-inference (optional standalone embeddings)
```

## Stacks

| Directory | What it is | Port(s) | Exposure |
| --- | --- | --- | --- |
| `npm` | nginx-proxy-manager, the router (tunnel + LAN entry) | 80, 443, 81 | all interfaces (defaults) |
| `npm-front` | nginx-proxy-manager, public-IP TLS edge | 80, 443, 82 | public 80/443, loopback admin |
| `anubis` | proof-of-work gateway for public-IP hostnames | 8923 | internal |
| `cloudflared` | Cloudflare tunnel connector | — | outbound only |
| `adguard` | DNS + DHCP server | 53, 3000 | host network |
| `host-tailscale` | Tailscale node / exit node | — | host network |
| `authentik` | identity provider (SSO, OIDC, LDAP) | 9000 | loopback |
| `crowdsec` | intrusion detection + nftables bouncer | 8080 | loopback |
| `socket-proxy` | Docker API metadata proxy | 2375 | loopback |
| `litellm-proxy` | OpenAI-compatible gateway + Presidio guardrails | 4000 | loopback |
| `omniroute` | model router / provider aggregator | 20128 | loopback |
| `open-webui` | chat UI (built locally, CVE patch) | 8080 | loopback |
| `hermes` | Hermes agent + dashboard | 8642, 9119 | loopback |
| `searxng` | metasearch for web-search tools | — | internal |
| `presidio` | PII analyzer + anonymizer | — | internal |
| `embedder` | HuggingFace TEI embeddings (bge-m3) | — | internal |
| `rembg` | background removal API | 7000 | loopback |
| `portainer` | container management UI | 9443 | loopback |
| `glances` | host system monitor | 61208 | host network |
| `uptime-kuma` | uptime monitoring | — | via `npm` |
| `homarr` | dashboard | 7575 | loopback |
| `it-tools` | dev/IT utilities | 8081 | loopback |
| `cyberchef` | encoding/crypto toolkit | 8000 | loopback |
| `web-check` | OSINT website analyzer | 3001 | loopback |
| `stirling-pdf` | PDF toolkit | 8082 | loopback |
| `snapotter` | image/video/audio/PDF processing | 1349 | loopback |
| `whoami` | echo service for proxy testing | 8080 | loopback |

Port defaults repeat across stacks (`8080` appears three times) because each host only
runs its assigned subset. Check for a collision before co-locating stacks.

## Deployment

1. Push to `main`.
2. GitHub Actions on a self-hosted runner diffs the push, takes the first path segment of
   every changed file, drops dot-directories, and deploys only those directories.
3. For each directory it SSHes to every host listed in `/etc/homelab/hosts.env`, using a
   key whose forced command runs `deploy-service.sh <dir>`:
   `git pull && docker compose pull && docker compose up -d --build --remove-orphans`.
4. `main` is mirrored to the public repository.

Consequences worth knowing:

- Root-level changes (`README.md`, `setup-target.sh`, `.github/**`) deploy nothing.
- The directory name is the deployment key. Renaming a stack stops its deploys until
  `hosts.env` and the hosts' sparse checkouts are updated.
- Hosts use `git sparse-checkout`, so only some stacks exist on any given host. A
  cross-directory mount (e.g. `crowdsec` reading `npm-front`'s logs) only works where
  both are checked out.
- A new stack needs `setup-target.sh` run on the host and a hand-created `.env`; CI
  cannot bootstrap either.
- Renovate pins image digests and opens the dependency bumps.

## Running a stack

```sh
cd litellm-proxy
# create the networks named in the header of .env.example, once per host
docker network create ai-net
docker network create --internal shared-ai-backend-net
# fill in every "changeme"; generate secrets with: openssl rand -hex 32
cp .env.example .env
docker compose up -d
```

Each directory reads **its own** `.env`. `HOST_IP` defaults to `127.0.0.1`, so a stack
publishes nothing beyond the host unless you set it; the only intentional all-interface
binds are `npm-front`'s 80/443 (and `npm`'s, when its port overrides are unset).

## Conventions

- Images are pinned by tag + `@sha256:` digest.
- `cap_drop: ALL` first, then the minimum `cap_add` the image's entrypoint needs.
- `no-new-privileges` on every service; `read_only` + `tmpfs` where stateless.
- Every service declares `deploy.resources.limits` — backstops, not budgets.
- Healthchecks probe a real endpoint on that image, with a `start_period` that covers
  boot.
- State is bind-mounted under the stack directory so backup tooling can see it; named
  volumes are the exception, used where the deployer must not need checkout write access.
- Comments explain *why*, including which upstream bug a choice works around.

`AGENTS.md` documents these rules in full, plus the network inventory and the traps in
each stack. Several directories have their own `AGENTS.md` for stack-specific details.

## Security posture

- Loopback-by-default publishing. Public exposure is deliberate and takes exactly two
  forms: the Cloudflare tunnel, and `npm-front`'s public 80/443 in front of Anubis.
- Secrets live in untracked per-stack `.env` files, referenced as `${VAR:?…}` so a missing
  value fails loudly instead of booting with an empty password.
- Services run with dropped capabilities. The Docker socket is exposed only through a
  proxy (`socket-proxy`) that allowlists API sections, and `portainer` talks to Docker
  through its own proxy rather than the socket directly.
- This is a homelab, not a turnkey deployment: several stacks need host networking, the
  Docker socket, privileged ports, and the AI stack assumes roughly 11 GB of RAM. Don't
  run the collection on a workstation as a smoke test.

## License

MIT — see [LICENSE](LICENSE).
