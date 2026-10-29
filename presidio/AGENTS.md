# presidio/

PII analysis + anonymization for the AI stack. Two stateless services
(`presidio-analyzer`, `presidio-anonymizer`) on `shared-ai-backend-net` only — no host
port, no egress, `read_only: true` with a `/tmp` tmpfs.

```
analyzer-config.yaml      SERVER config  -> ANALYZER_CONF_FILE
secret_recognizers.yaml   REGISTRY       -> RECOGNIZER_REGISTRY_CONF_FILE
```

## The two-file trap

This image reads **two different files** through **two different env vars**, and the wrong
names are silently ignored:

| Purpose | Env var | Top-level key |
| --- | --- | --- |
| NLP engine / threshold | `ANALYZER_CONF_FILE` | `nlp_configuration` |
| Recognizer list | `RECOGNIZER_REGISTRY_CONF_FILE` | `recognizers` |

- `ANALYZER_REGISTRY_CONF_FILE` does **not** exist. Setting it is a no-op and the registry
  falls back to the image default, so every custom pattern vanishes with no error.
- Putting `recognizer_registry` in the server config, or `nlp_configuration` in the
  registry, makes gunicorn exit code 3 and crash-loop.
- In the registry, predefined recognizers use `supported_languages:` (plural); custom ones
  use `supported_language:` (singular).

## Registry is replaced, not merged

The list in `secret_recognizers.yaml` **replaces** the image's registry wholesale.
Omitting a built-in removes that entity from `/supportedentities` — which is why every
built-in is spelled out even though it looks redundant.

## Threshold

`default_score_threshold: 0.4` is deliberate. At `0` any 13+ digit run scores as
`US_BANK_NUMBER` (a Unix timestamp came back as one). Real detections score 0.75–1.0.

## Memory

`presidio-analyzer` gets `2g` because `en_core_web_lg` is ~800MB of weights and loads
fully resident; a 1g ceiling OOM-kills it on the first request. `presidio-anonymizer` is a
stateless transform with no model, so `256m` is enough.

## Changing recognizers

1. Edit `secret_recognizers.yaml`.
2. `docker compose up -d` (the analyzer re-reads on restart).
3. `curl`-free verification from the host:
   `../litellm-proxy/test-guardrails.sh --entities` and then the full script. A
   recognizer that "works" on a hand-typed sample usually means the sample was malformed —
   the test script builds payloads (Luhn-valid card, correctly sized tokens) on purpose.

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```
