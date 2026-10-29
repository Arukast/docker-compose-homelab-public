# litellm-proxy/

OpenAI-compatible gateway in front of OmniRoute, with Presidio PII guardrails. Also the
only client-facing entry to the AI stack: `open-webui` and `hermes-agent` both point at
`http://litellm-proxy:4000/v1` with `LITELLM_MASTER_KEY`.

```
litellm-config.yaml    model routes + guardrail wiring, mounted at /app/config.yaml
test-guardrails.sh     end-to-end self-check (run on the Docker host)
postgres_data/         runtime, never commit
```

## Routing scheme

`litellm-config.yaml` declares three model entries, matched most-specific first:

- `protected/*` → OmniRoute **through** the `presidio-pii` guardrail.
- `raw/*` → OmniRoute directly, **no** guardrail.
- `*` → catch-all, also guarded.

Clients pick the prefix in the model name. Keep that scheme: an unguarded path should be
explicit (`raw/`), never the default. A literal model name beats a wildcard, so adding a
specific route can silently bypass the catch-all's guardrail — attach `presidio-pii`
yourself if that route should be protected.

## Traps

- **`database_url` is required.** Open WebUI's test-connection calls `/model/info`, which
  returns `500 "No connected db."` without it. The `postgres` sidecar exists for exactly
  that; it is not optional bookkeeping.
- **Upstream credentials are OmniRoute's**, supplied via
  `os.environ/OMNIROUTE_API_BASE` / `OMNIROUTE_API_KEY`. Clients of this proxy use
  `LITELLM_MASTER_KEY` instead. `hermes/.env` calls this out because mixing the two is the
  usual mistake.
- **Guardrail entities are mapped here, recognizers are not.** The `pii_entities_config`
  block decides what gets masked; the patterns that detect a secret live in
  `presidio/secret_recognizers.yaml`.
- Networks: `ai-net` for egress and to reach `omniroute`, `shared-ai-backend-net` for
  `presidio-*` and postgres. Presidio publishes no host port, so it is reachable only from
  that network.
- The prod entrypoint starts as root and drops privileges, hence the
  `CHOWN`/`SETUID`/`SETGID` trio.
- `memory: 4g` follows upstream's documented production floor; it previously sat at 95%
  utilization on 1g.

## Testing guardrails

`test-guardrails.sh` runs on the Docker host (it shells out to `docker` and `curl`) and
reaches Presidio from a throwaway container on `shared-ai-backend-net`:

```sh
./test-guardrails.sh             # analyse, anonymize, then the litellm routes
./test-guardrails.sh -v          # show what Presidio actually returned
./test-guardrails.sh --entities  # every entity the analyzer supports
```

Test payloads are built, never typed: a miscounted literal looks identical to a broken
recognizer. If a route check reports a missing model, check `/model/info` — routes whose
upstream is dead are still listed.

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```
