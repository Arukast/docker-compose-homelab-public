# embedder/

Standalone CPU embedding service (HuggingFace TEI + bge-m3), split out so the ~2.3GB
model does not live inside the `open-webui` process.

Two services, deliberately staged:

- `model-fetch` — one-shot, `restart: "no"`, on `ai-net` (has egress). Downloads weights
  into the **named volume** `tei-model`, then exits 0 and stays exited.
- `text-embeddings-inference` — on `shared-ai-backend-net` (internal, no egress), gated by
  `service_completed_successfully`, reads `/model` read-only.

## Why it looks like this

- The named volume (not a bind mount) exists so the `deployer` user never needs write
  access to the checkout. `compose up --build` was exhausting disk on the export step
  when the model came from the image.
- The guard checks `pytorch_model.bin` **and** `Pytorch_model.bin`. The Hub file is
  capital-P; a lowercase-only guard never fired and every deploy re-walked the Hub.
- `ignore_patterns` (ONNX, ColBERT/sparse heads, images, markdown) is why it is 2.3GB and
  not 4.3GB.
- There is **no `.env`** in this directory. `EMBED_MODEL` is only read from the shell
  environment; export it before `compose up` if you need a different model.

## TEI flags are load-bearing

| Flag | Why |
| --- | --- |
| `--pooling cls` | bge-m3 is CLS-pooled. Wrong pooling silently returns garbage vectors that still look valid. |
| `--dtype float16` | Halves the weights (~2.27GB → ~1.15GB). CPU-only box, 11GB LXC. |
| `--max-batch-tokens 8192` | bge-m3 caps at 8192 anyway; the 16384 default only inflates warmup peaks. |
| `--max-concurrent-requests 32` | 512 in flight is GPU sizing; on CPU it is contention. |
| ~~`--normalize`~~ | **Rejected by cpu-1.8** ("unexpected argument") and the container crash-loops. |

Verify any new flag first — an unrecognised one takes the service down, and while TEI is
down `open-webui` silently falls back to downloading the model itself:

```sh
docker compose run --rm text-embeddings-inference --help
```

## Memory

`memory: 4g` on TEI is a deliberate ceiling, not a mistake to "fix". The documented
history: the LXC hit 11.8GB total while this container reported ~805MiB, Proxmox SIGKILLed
it above the Docker layer (`.State.OOMKilled` reads false), and raising the limit only
bought dead space. If it is still SIGKILLed at 4g, the honest conclusion is that bge-m3 on
CPU does not fit here — go back to in-process embeddings in `open-webui`, don't raise it.

## Relationship to openwebui

`open-webui` currently runs embeddings **in process** (`RAG_EMBEDDING_ENGINE=` is empty)
and its memory limit reflects that. This stack is the alternative, not an addition — do
not have both load bge-m3 unless the host has RAM for two copies.

## Validate

```sh
docker compose --project-directory . -f docker-compose.yml config --quiet
```
