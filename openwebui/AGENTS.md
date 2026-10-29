# openwebui/

Open WebUI chat UI. Talks to `litellm-proxy` for models, `searxng` for web search,
`rembg` for the background-removal pipe function, and `authentik` for OIDC.

```
Dockerfile.open-webui          local build, pins upstream base + one security patch
open-webui-data/               runtime state (gitignored) EXCEPT functions/
open-webui-data/functions/     tracked source: pipe functions, mounted by the app
```

## Build, not a plain image

`Dockerfile.open-webui` pins `ghcr.io/open-webui/open-webui:v0.12.4@sha256:...` and
upgrades `sentence-transformers>5.5.1` to patch CVE-2026-68770 (arbitrary code execution
on local model load, even with `trust_remote_code=False`). Keep the patch until upstream
ships a fixed base, and let Renovate bump the base — it manages `dockerfile` alongside
`docker-compose`.

## functions/ is source

`open-webui-data/*` is gitignored with `!open-webui-data/functions/`. Those files are
tracked because they are code, not state.

- The module docstring is parsed as **YAML** by Open WebUI. Keep `description:` a block
  scalar (`|`): a bare `": "` or `" #"` in a plain scalar either errors or truncates, and
  the function silently never loads.
- `remove_background.py` calls `http://rembg:7000/api/remove` — path is `/api/remove`,
  **not** `/api/v1/remove` (the v1 prefix 404s on this image). It uses
  `isnet-general-use` rather than rembg's default `u2net`.
- A pipe function must return a plain **string**. A dict is returned to the client as a
  raw response body and never renders.

## Traps

- **Embeddings run in process** (`RAG_EMBEDDING_ENGINE=` is empty, model `BAAI/bge-m3`).
  That is why the limit is `5g`: the ~2.3GB weights must stay resident and chat + RAG
  share one ceiling. `embedder/` exists as the standalone alternative — do not enable both.
- **`OPENAI_API_KEY` is `litellm-proxy`'s `LITELLM_MASTER_KEY`**, not OmniRoute's key.
- OIDC: provider vars are commented out in `.env.example` until authentik is configured.
  `ENABLE_PERSISTENT_CONFIG` must be set for the admin UI's OAuth settings to survive a
  restart, and the OIDC redirect URI must match the public URL exactly.
- Container creates files in `./open-webui-data`, which is deployer-owned on this fleet, so
  the root process needs `DAC_OVERRIDE`/`FOWNER` (plus `CHOWN` for `start.sh` re-owning).
- Networks: `ai-net` (litellm, searxng, rembg) and `shared-ai-backend-net` (presidio, TEI).

## Validate

```sh
HOST_IP=127.0.0.1 docker compose --project-directory . --env-file .env.example \
  -f docker-compose.yml config --quiet
```

A function or OIDC change needs a container restart plus a look at `docker logs open-webui`;
none of it fails at `compose up` time.
