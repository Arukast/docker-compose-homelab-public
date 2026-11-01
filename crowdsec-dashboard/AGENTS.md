# crowdsec-dashboard/

Self-hosted CrowdSec UI (`crowdsec-web-ui`). Reads the independent LAPIs on
OCI-Core and OCI-Production; it never writes enforcement data — the CAPI
community blocklist and all decisions stay in each engine.

```
docker-compose.yml   the UI, two instances, npm-net
data/                state.db + cache.db   runtime, gitignored
```

## Traps

- **It is a reader, not a component of the detection path.** Recreating or losing this
  stack does not change what is blocked.
- **It needs a machine credential on each LAPI.** Each password in `.env` must match the
  one passed to `cscli machines add crowdsec-web-ui --password ... -f /dev/null` on that
  host. The `-f /dev/null` is mandatory.
- **`data/state.db` is the durable half** (users, passkeys, sessions, notification
  destinations/rules, saved filters). `cache.db` is rebuilt from LAPI on loss. Back up the
  directory, not individual files — WAL mode adds `cache.db-wal` / `cache.db-shm`.
- **Alert deletion needs `api.server.trusted_ips` on the LAPI side** (see
  `crowdsec/config.yaml.local`). Without it the UI authenticates but gets 403 on delete.
- **Metrics URLs must point at `:6060/metrics`**, published by the `crowdsec` stack on
  `HOST_IP`. The LAPI (8080) does not expose metrics.
- **It must join `npm-net`** so npm can forward to `crowdsec-web-ui:3000`. The HOST_IP
  publish is only for tailnet/direct troubleshooting.
- **Host port is 3005, not 3000.** AdGuard runs on the host network of OCI-Core and owns
  `*:3000`, so the compose default is 3005. The container port stays 3000, which is why
  the npm proxy host forwards to `crowdsec-web-ui:3000`.
- `https://...` vhost is required for passkeys: WebAuthn needs a secure context, so a
  reverse proxy terminating TLS is not optional.
- The image ships its own HEALTHCHECK; `/api/health` is intentionally public.
- CAPI-sourced alerts are hidden by default (`crowdsec.alertFilters.includeCapi: false`)
  while CAPI decisions still appear under Decisions.
