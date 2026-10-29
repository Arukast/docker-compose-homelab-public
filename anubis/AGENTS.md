# anubis/

Proof-of-work bot gateway. One instance covers every website served over the host's
**public IP** — Anubis is Host-agnostic, so there is nothing per-site here.

```
anubis/policy.yaml    bot policy, mounted read-only at /data/cfg/botPolicy.yaml
```

Chain (public-IP path): internet → `npm-front` (TLS edge) → `anubis:8923` → `npm:80` →
service. Services published through the **cloudflared tunnel** reach `npm` directly and
never pass through Anubis — Cloudflare is their protection, which is why the bypass list
below only has to cover public-IP hostnames.

## Policy file

- **Rules match top to bottom and the first match wins.** Bypasses go first; the upstream
  default rule set is imported last via `import: (data)/meta/default-config.yaml`. Adding
  a rule below that import makes it dead code.
- Native clients that cannot solve a challenge (apps, sync engines, appliances, webhooks)
  need an `ALLOW` rule **above** the import. Prefer `path_regex`; `user_agent_regex` and
  `headers_regex` are spoofable on their own. Commented templates for Home Assistant,
  Nextcloud and DoH are already in the file.
- Tailscale (`100.64.0.0/10`) and `Authorization: Bearer|Basic` clients are bypassed
  globally. authentik's `/outpost.goauthentik.io/*` paths must stay allowed or the
  forward-auth login redirect gets challenged.

## Environment

- `ANUBIS_TARGET` is the router behind the gateway, e.g. `http://nginx-proxy-manager:80`.
- `ANUBIS_ED25519_PRIVATE_KEY_HEX` signs challenge cookies; it must be exactly 64 hex
  chars (`openssl rand -hex 32`), so a malformed value fails at startup. Rotating it
  invalidates every issued pass cookie.
- `ANUBIS_COOKIE_DOMAIN` sets one pass cookie for all subdomains. It also seeds
  `REDIRECT_DOMAINS`; leaving that open is the "Redirect domain not allowed" risk in the
  startup log.
- The image runs as uid 1000 on unprivileged `:8923`, so it carries no capabilities. Do
  not add a `cap_add` here.

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```

After a policy change, restart the container and read the startup log — a malformed rule
is reported there, not at `compose up` time.
