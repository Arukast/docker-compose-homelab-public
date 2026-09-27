#!/usr/bin/env bash
# Self-check for the Presidio secret recognizers and the LiteLLM presidio guardrail.
#
#   ./test-guardrails.sh          # everything that is up
#   ./test-guardrails.sh -v       # show what presidio actually returned
#   ./test-guardrails.sh --raw "some text"   # dump the raw /analyze response
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
in_net() { docker run --rm --network "$NET" --entrypoint python3 "$SCRATCH" -q -c "$1"; }

# The helpers print ERR:<code>:<body> instead of dying, so a broken endpoint can
# never be misread as "nothing found" -> false PASS.
is_err()    { case "$1" in ERR:*) return 0;; *) return 1;; esac; }
has()       { case " $1 " in *" $2 "*) return 0;; *) return 1;; esac; }
has_choice() { case "$1" in *'"choices"'*) return 0;; *) return 1;; esac; }

# Raw dump mode -- use this when a check fails and the reason is not obvious.
if [ "${1:-}" = "--raw" ]; then
  in_net "
import json,urllib.request
r=urllib.request.Request('$ANALYZER/analyze',json.dumps({'text':'''${2:-}''','language':'en'}).encode(),{'Content-Type':'application/json'})
print(json.dumps(json.load(urllib.request.urlopen(r,timeout=60)),indent=2))
"
  exit 0
fi

# analyze <text> -> entity types presidio found, space separated
analyze() { in_net "
import json,urllib.request,urllib.error
r=urllib.request.Request('$ANALYZER/analyze',json.dumps({'text':'''$1''','language':'en'}).encode(),{'Content-Type':'application/json'})
try:
    d=json.load(urllib.request.urlopen(r,timeout=60))
except urllib.error.HTTPError as e:
    print('ERR:%s:%s'%(e.code,e.read()[:300].decode('utf-8','replace'))); raise SystemExit
res=d if isinstance(d,list) else d.get('results',[])
print(' '.join(x.get('entity_type','') for x in res))
"; }

# anonymize <text> -> the masked text
anonymize() { in_net "
import json,urllib.request,urllib.error
r=urllib.request.Request('$ANONYMIZER/anonymize',json.dumps({'text':'''$1''','language':'en','anonymizers':[{'type':'replace','new_value':'<ENTITY>'}]}).encode(),{'Content-Type':'application/json'})
try:
    d=json.load(urllib.request.urlopen(r,timeout=60))
except urllib.error.HTTPError as e:
    print('ERR:%s:%s'%(e.code,e.read()[:300].decode('utf-8','replace'))); raise SystemExit
print(d.get('text','') if isinstance(d,dict) else d)
"; }

# ---------------------------------------------------------------- analyzer
head_ "presidio-analyzer"

ents=$(analyze "hello world, nothing to see")
if is_err "$ents"; then bad "analyzer reachable" "$ents"
elif [ -n "$ents" ]; then bad "benign text is clean" "got: $ents"
else ok "benign text is clean"; fi

# Length-sensitive fixtures are built, not hand-typed: a miscounted literal
# looks identical to a broken recognizer.
SK_OR="sk-or-v1-$(printf '0123456789abcdef%.0s' 1 2 3 4)"          # 64 hex
AGE="AGE-SECRET-KEY-1$(printf 'q%.0s' $(seq 58))"                 # 58 chars

# Each probe is <literal payload>|<expected entity>. Expect ANY means "detected
# something" -- used for the built-in recognizers, whose entity names shift
# between presidio versions (CREDIT_CARD vs CREDIT_DEBIT_CARD_NUMBER).
for probe in \
  "[SECRET:aws-access-key-id]|SECRET_KEY" \
  "[SECRET:github-token]|SECRET_KEY" \
  "[SECRET:gitlab-personal-access-token]|SECRET_KEY" \
  "$SK_OR|SECRET_KEY" \
  "[SECRET:slack-token]|SECRET_KEY" \
  "$AGE|SECRET_KEY" \
  'john.doe@example.com|ANY' \
  '4111111111111111|ANY' \
  '123-45-6789|ANY' \
  '+1-555-123-4567|ANY'
do
  text="${probe%%|*}"; want="${probe##*|}"
  got=$(analyze "$text")
  [ "$VERBOSE" -eq 1 ] && printf '       want=%-13s got=%s\n' "$want" "${got:-<none>}"
  if is_err "$got"; then bad "$text" "analyzer error: $got"
  elif [ "$want" = "ANY" ]; then
    if [ -n "$got" ]; then ok "detected in: $text  [$got]"; else bad "detected in: $text" "nothing detected"; fi
  elif has "$got" "$want"; then ok "detected in: $text"
  else bad "detected in: $text" "expected $want, got: ${got:-<none>}"; fi
done

# -------------------------------------------------------------- anonymizer
head_ "presidio-anonymizer"
out=$(anonymize "mail me at [EMAIL]")
case "$out" in
  ERR:*)     bad "anonymizer masks" "$out" ;;
  *[EMAIL]*) bad "anonymizer masks" "leaked: $out" ;;
  *)         ok "anonymizer masks" ;;
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
      -d '{"model":"protected/ANY","messages":[{"role":"user","content":"Repeat exactly: key [SECRET:aws-access-key-id]"}],"max_tokens":60}' \
      "$LITELLM/v1/chat/completions")
    # Shape first, then leak: an error body is not a pass.
    if ! has_choice "$r"; then
      bad "post_call masks output secrets" "no choices in reply: $(printf '%s' "$r" | cut -c1-200)"
    elif [ "${r#*[SECRET:aws-access-key-id]}" != "$r" ]; then
      bad "post_call masks output secrets" "echoed the key back"
    else
      ok "post_call masks output secrets"
    fi
    [ "$VERBOSE" -eq 1 ] && printf '       %s\n' "$r"
  else
    skip "litellm route tests (LITELLM_MASTER_KEY not exported)"
  fi
else
  skip "litellm not reachable at $LITELLM (HTTP $code)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
