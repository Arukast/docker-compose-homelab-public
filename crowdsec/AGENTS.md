# crowdsec/

Detection engine (`crowdsec`) plus a firewall remediation component
(`crowdsec-firewall-bouncer`, host network, nftables).

```
crowdsec/acquis.d/*.yaml                log sources         TRACKED (source)
crowdsec/crowdsec-firewall-bouncer.yaml bouncer config      TRACKED (source)
crowdsec/config/  crowdsec/data/        hub, SQLite, GeoIP   runtime, gitignored
```

## Traps

- **The bouncer config goes through `envsubst`.** Only `${API_URL}` and `${API_KEY}` may
  appear in it; any other `${...}` literal is blanked at startup and the bouncer comes up
  misconfigured.
- **`../npm-front/npm-front/data/logs` is a cross-directory mount.** Hosts use sparse
  checkout, so it only resolves when both `crowdsec` and `npm-front` are deployed to the
  same host. It is deliberate: only the TLS edge sees real client IPs, so bans stay
  meaningful. The internal router's logs carry the gateway's IP.
- **Host logs mount at `/var/log/host`, never at `/var/log`.** Mounting the host's
  `/var/log` read-only at `/var/log` makes Docker unable to create the nested
  `/var/log/npm` mountpoint (EROFS) and the container fails to start.
- **`:8080` is the LAPI port** and is published on `HOST_IP`. Do not co-locate other
  services that want 8080 (`npm/.env.example` warns about this: NPM must not take 8080 on
  the edge host).
- **External DNS override is required on OCI**, where the VCN resolver
  (`169.254.169.254`) is unreachable from containers and the hub install fetches
  `version.crowdsec.net` on every start.
- The bouncer needs `NET_ADMIN` + `NET_RAW` because it manipulates host nftables; the
  engine needs `DAC_OVERRIDE` only to read root-owned host logs.
- **`config.yaml.local` is the only tracked engine config.** `crowdsec/crowdsec/config/` is
  image-seeded runtime state — an edit there is lost on reseed. The override is mounted as
  a single file on top of that directory mount. Its `trusted_ips` must include
  `100.64.0.0/10`: the dashboard on OCI-Core reaches the *other* host's LAPI from a Tailscale
  IP, and alert deletion is IP-gated.
- **`6060` is the Prometheus collector**, published on `HOST_IP` next to `8080`. The image
  already binds it to `0.0.0.0:6060` inside the container, so `config.yaml.local` must not
  re-declare it.
- **The blocklist comes from CAPI, not from the dashboard or the Console.** Tier is
  plan + contribution driven (Lite ~3k / Community ~15k / Premium ~60k) and only official,
  unmodified Hub scenarios count as contribution. Never set `DISABLE_ONLINE_API` unless you
  knowingly give up the feed.
- **The hosts are independent LAPIs:** no decision is shared, so a ban on one host does not
  protect the other. Cross-host enforcement means the distributed setup (one LAPI + remote
  agents/bouncers), not a config tweak here.
- **`crowdsec-dashboard` (sibling stack) holds one machine credential per LAPI.** Wiping
  `crowdsec/data/` or deleting that machine breaks the dashboard with 403s until
  `cscli machines add crowdsec-web-ui --password ... -f /dev/null` is re-run. `-f /dev/null`
  is mandatory, otherwise `cscli` overwrites the container's `local_api_credentials.yaml`.
- On hosts without `npm-front` (e.g. `OCI-Production`), the cross-directory log mount creates
  an empty directory: expected, the engine simply has no HTTP logs there.
- Changing `CUSTOM_HOSTNAME` on an already-running host registers the new machine but leaves
  the old one behind (it was `localhost`). Drop it once:
  `docker compose exec crowdsec cscli machines delete localhost`.
- This stack deploys to **two** hosts via `hosts.env`; the dashboard is a separate directory
  so it can target OCI-Core alone.

## Adding a log source

1. Drop a file in `crowdsec/acquis.d/` with `filenames:` and a `labels.type` that matches
   an installed parser (see the two existing files).
2. Mount the log directory into the container.
3. Add the matching collection to `CROWDSEC_COLLECTIONS` in `.env` if one is required.
4. Restart and check `docker logs crowdsec` — acquis errors appear there.

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```
