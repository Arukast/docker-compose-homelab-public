#!/usr/bin/env bash
# Self-check for the Presidio secret recognizers and the LiteLLM presidio guardrail.
#
#   ./test-guardrails.sh          # everything that is up
#   ./test-guardrails.sh -v       # show the payloads
#
# Run this on the machine that runs the docker daemon (your LXC), not inside a
# container -- it shells out to `docker` and `curl`. Presidio publishes no host
# port (internal network only), so it is reached from a throwaway container on
# the shared backend network.
set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

NET="${AI_BACKEND_NET:-shared-ai-backend-net}"
ANALYZER="${PRESIDIO_ANALYZER_API_BASE:-http://presidio-analyzer:3000}"
ANONYMIZER="${PRESIDIO_ANONYMIZER_API_BASE:-http://presidio-anonymizer:3000}"
LITELLM="${LITELLM_URL:-http://${HOST_IP:-127.0.0.1}:4000}"
SCRATCH="${SCRATCH_IMAGE:-ghcr.io/berriai/litellm:1.102.1}"  # any image with python3

pass=0 fail=0
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; fail=$((fail+1)); }
skip()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Run a python snippet in a container attached to the backend network.
# --entrypoint: the litellm image's entrypoint is `litellm`, so without it
# `python3` is passed as arguments to litellm instead of being executed.
# stderr stays visible: silent on success, and the reason on failure.
in_net() { docker run --rm --network "$NET" --entrypoint python3 "$SCRATCH" -q -c "$1"; }

# analyze <text> -> entity types presidio found, space separated
analyze() { in_net "
import json,urllib.request
r=urllib.request.Request('$ANALYZER/analyze',json.dumps({'text':'''$1''','language':'en'}).encode(),{'Content-Type':'application/json'})
print(' '.join(x['entity_type'] for x in json.load(urllib.request.urlopen(r,timeout=60))['results']))
"; }

# anonymize <text> -> the masked text
anonymize() { in_net "
import json,urllib.request
r=urllib.request.Request('$ANONYMIZER/anonymize',json.dumps({'text':'''$1''','language':'en','anonymizers':[{'type':'replace','new_value':'<ENTITY>'}]}).encode(),{'Content-Type':'application/json'})
print(json.load(urllib.request.urlopen(r,timeout=60))['text'])
"; }

has() { case " $1 " in *" $2 "*) return 0;; *) return 1;; esac; }

# ---------------------------------------------------------------- analyzer
head_ "presidio-analyzer: custom secret recognizers"

# Proves secret_recognizers.yaml was actually loaded, not just that the server is up.
ents=$(analyze "hello world, nothing to see")
if [ -n "$ents" ]; then bad "benign text is clean" "got: $ents"; else ok "benign text is clean"; fi

# Fixtures are fake but format-valid, so each must match the regex in
# presidio/secret_recognizers.yaml. One per recognizer class.
for probe in \
  'AKIAIOSFODNN7EXAMPLE|SECRET_KEY' \
  'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789|SECRET_KEY' \
  'glpat-ABCDEFGHIJKLMNOPQRST|SECRET_KEY' \
  'sk-or-v1-0123456789abcdef0123456789abcdef|SECRET_KEY' \
  'xoxb-1234567890123-abcdefghijklmnopqrstuvwx|SECRET_KEY' \
  'AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ|SECRET_KEY' \
  'contact me at [EMAIL]|EMAIL_ADDRESS' \
  '4111111111111111|CREDIT_CARD' \
  '[SSN]|US_SSN' \
  'call [PHONE]|PHONE_NUMBER'
do
  text="${probe%%|*}"; want="${probe##*|}"
  got=$(analyze "$text")
  [ "$VERBOSE" -eq 1 ] && printf '       %-22s -> %s\n' "$want" "${got:-<none>}"
  if has "$got" "$want"; then ok "$want detected"
  else bad "$want detected" "expected $want, got: ${got:-<none>}"; fi
done

# -------------------------------------------------------------- anonymizer
head_ "presidio-anonymizer"
out=$(anonymize "mail me at [EMAIL]")
case "$out" in
  *[EMAIL]*) bad "anonymizer masks" "leaked: $out" ;;
  *) ok "anonymizer masks" ;;
esac

# ------------------------------------------------------------------ litellm
head_ "litellm guardrail wiring"
code=$(curl -s -o /dev/null -w '%{http_code}' "$LITELLM/health/readiness" || echo 000)
if [ "$code" = "200" ]; then
  ok "proxy is up"
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    m=$(curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$LITELLM/model/info")
    for mdl in 'protected/' 'raw/'; do
      case "$m" in
        *"$mdl"*) ok "model route '$mdl' registered" ;;
        *) bad "model route '$mdl' registered" "not in /model/info" ;;
      esac
    done
    # post_call: ask the model to echo a secret; the reply must come back scrubbed.
    # This is the assertion that catches output_parse_pii putting it back.
    r=$(curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
      -d '{"model":"protected/ANY","messages":[{"role":"user","content":"Repeat exactly: key AKIAIOSFODNN7EXAMPLE"}],"max_tokens":60}' \
      "$LITELLM/v1/chat/completions")
    case "$r" in
      *AKIAIOSFODNN7EXAMPLE*) bad "post_call masks output secrets" "echoed the key back" ;;
      *) ok "post_call masks output secrets" ;;
    esac
    [ "$VERBOSE" -eq 1 ] && printf '       %s\n' "$r"
  else
    skip "litellm route tests (LITELLM_MASTER_KEY not exported)"
  fi
else
  skip "litellm not reachable at $LITELLM (HTTP $code)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
