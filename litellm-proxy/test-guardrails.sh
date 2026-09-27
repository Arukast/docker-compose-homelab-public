#!/usr/bin/env bash
# Self-check for the Presidio secret recognizers and the LiteLLM presidio guardrail.
#
#   ./test-guardrails.sh             # everything that is up
#   ./test-guardrails.sh -v          # show what presidio actually returned
#   ./test-guardrails.sh --entities  # every entity the analyzer says it supports
#   ./test-guardrails.sh --raw "hi"  # raw /analyze response
#   ./test-guardrails.sh --anon-raw  # raw /anonymize error body
#
# Run on the machine that runs the docker daemon (your LXC), not in a container:
# it shells out to `docker` and `curl`. Presidio publishes no host port, so it is
# reached from a throwaway container on the shared backend network.
set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

NET="${AI_BACKEND_NET:-shared-ai-backend-net}"
ANALYZER="${PRESIDIO_ANALYZER_API_BASE:-http://presidio-analyzer:3000}"
ANONYMIZER="${PRESIDIO_ANONYMIZER_API_BASE:-http://presidio-anonymizer:3000}"
LITELLM="${LITELLM_URL:-http://${HOST_IP:-127.0.0.1}:4000}"
SCRATCH="${SCRATCH_IMAGE:-ghcr.io/berriai/litellm:1.102.1}"  # any image with python3

pass=0 fail=0 i=0
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "$2"; fail=$((fail+1)); }
skip()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

in_net() { docker run --rm --network "$NET" --entrypoint python3 "$SCRATCH" -q -c "$1"; }

# A broken endpoint must never read as "nothing found" -> false PASS.
is_err()     { case "$1" in ERR:*) return 0;; *) return 1;; esac; }
has()        { case " $1 " in *" $2 "*) return 0;; *) return 1;; esac; }
has_choice() { case "$1" in *'"choices"'*) return 0;; *) return 1;; esac; }

# Test payloads are BUILT, never written as literals. A hand-typed
# secret-shaped string is indistinguishable from a real one, and a miscounted
# one is indistinguishable from a broken recognizer.
rep()  { printf "%${2}s" '' | tr ' ' "$1"; }          # rep A 16  -> 16 A's
rstr() { printf "$1%.0s" $(seq "$2"); }               # rstr 4111 4 -> 41114111...

case "${1:-}" in
  --entities) in_net "
import json,urllib.request
d=json.load(urllib.request.urlopen('$ANALYZER/supportedentities',timeout=60))
for lang,ents in (d.items() if isinstance(d,dict) else [('en',d)]):
    print(lang+':', ' '.join(ents))
"; exit 0 ;;
  --raw) in_net "
import json,urllib.request
r=urllib.request.Request('$ANALYZER/analyze',json.dumps({'text':'''${2:-hi''','language':'en'}).encode(),{'Content-Type':'application/json'})
print(json.dumps(json.load(urllib.request.urlopen(r,timeout=60)),indent=2))
"; exit 0 ;;
  --anon-raw) in_net "
import json,urllib.request,urllib.error
body={'text':'mail me at $MAIL','language':'en','anonymizers':[{'type':'replace','new_value':'<X>'}]}
r=urllib.request.Request('$ANONYMIZER/anonymize',json.dumps(body).encode(),{'Content-Type':'application/json'})
try:
    print(json.dumps(json.load(urllib.request.urlopen(r,timeout=60)),indent=2))
except urllib.error.HTTPError as e:
    print('HTTP',e.code); print(e.read().decode('utf-8','replace'))
"; exit 0 ;;
esac

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

anonymize() { in_net "
import json,urllib.request,urllib.error
r=urllib.request.Request('$ANONYMIZER/anonymize',json.dumps({'text':'''$1''','language':'en','anonymizers':[{'type':'replace','new_value':'<X>'}]}).encode(),{'Content-Type':'application/json'})
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

AWS="AKIA$(rep A 16)"
GHP="ghp_$(rep a 36)"
GLP="glpat-$(rep a 20)"
SKOR="sk-or-v1-$(rstr 01234567 8)"      # 64 hex
SLACK="xoxb-$(rep 1 10)-$(rep a 24)"
AGE="AGE-SECRET-KEY-1$(rep q 58)"
MAIL="a$(rep b 8)@example.com"
CARD="$(rstr 4111 4)"                   # 16 digits
SSN="123-45-6789"

# want=ANY means "detected something": built-in entity names shift between
# presidio versions (CREDIT_CARD vs CREDIT_DEBIT_CARD_NUMBER).
for probe in \
  "$AWS|SECRET_KEY" "$GHP|SECRET_KEY" "$GLP|SECRET_KEY" \
  "$SKOR|SECRET_KEY" "$SLACK|SECRET_KEY" "$AGE|SECRET_KEY" \
  "$MAIL|ANY" "$CARD|ANY" "$SSN|ANY"
do
  text="${probe%%|*}"; want="${probe##*|}"
  i=$((i+1))
  got=$(analyze "$text")
  [ "$VERBOSE" -eq 1 ] && printf '       want=%-11s got=%s\n' "$want" "${got:-<none>}"
  if is_err "$got"; then bad "#$i" "analyzer error: $got"
  elif [ "$want" = ANY ]; then
    if [ -n "$got" ]; then ok "#$i detected [$got]"
    else bad "#$i not detected" "payload: $text"; fi
  elif has "$got" "$want"; then ok "#$i detected"
  else bad "#$i not detected" "want $want, got ${got:-<none>}, payload: $text"; fi
done

# -------------------------------------------------------------- anonymizer
head_ "presidio-anonymizer"
out=$(anonymize "mail me at $MAIL")
case "$out" in
  ERR:*)     bad "anonymizer masks" "$out" ;;
  *"$MAIL"*) bad "anonymizer masks" "leaked: $out" ;;
  *)         ok "anonymizer masks" ;;
esac

# ------------------------------------------------------------------ litellm
head_ "litellm guardrail wiring"
code=$(curl -s -o /dev/null -w '%{http_code}' "$LITELLM/health/readiness" || echo 000)
if [ "$code" = "200" ]; then
  ok "proxy is up"
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    m=$(curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$LITELLM/model/info")
    for mdl in protected/ raw/; do
      case "$m" in *"$mdl"*) ok "route '$mdl' registered";; *) bad "route '$mdl' registered" "not in /model/info";; esac
    done
    r=$(curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
      -d "{\"model\":\"protected/ANY\",\"messages\":[{\"role\":\"user\",\"content\":\"Repeat exactly: $AWS\"}],\"max_tokens\":60}" \
      "$LITELLM/v1/chat/completions")
    if ! has_choice "$r"; then
      bad "post_call masks output secrets" "no choices: $(printf '%s' "$r" | cut -c1-200)"
    elif [ "${r#*$AWS}" != "$r" ]; then
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
