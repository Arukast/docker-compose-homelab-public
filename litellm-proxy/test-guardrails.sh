#!/usr/bin/env bash
# Self-check for the Presidio secret recognizers and the LiteLLM presidio guardrail.
#
#   ./test-guardrails.sh             # everything that is up
#   ./test-guardrails.sh -v          # show what presidio actually returned
#   ./test-guardrails.sh --entities  # every entity the analyzer says it supports
#   ./test-guardrails.sh --raw "hi"  # raw /analyze response
#   ./test-guardrails.sh --anon-raw  # raw /anonymize response or error
#
# Run on the machine that runs the docker daemon (your LXC), not in a container:
# it shells out to `docker` and `curl`. Presidio publishes no host port, so it is
# reached from a throwaway container on the shared backend network.
set -uo pipefail

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

# Pick up HOST_IP / LITELLM_MASTER_KEY from .env so this does not silently SKIP
# the litellm section every run. Anything already exported wins.
ENVFILE="${TEST_ENV_FILE:-$(dirname "$0")/.env}"
if [ -f "$ENVFILE" ]; then
  set -a; . "$ENVFILE"; set +a
fi

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

# Pull just the assistant text out of a chat/completion envelope. Anything that
# greps the raw JSON also hits "created" (a 13-digit unix timestamp) and reports
# an envelope field as a leaked secret.
content_of() { py - "$1" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(""); raise SystemExit
ch = d.get("choices") or []
if not ch:
    print(""); raise SystemExit
print(((ch[0].get("message") or {}).get("content")) or "")
PY
}

# Python is fed over stdin from a quoted heredoc and the URL/text arrive as argv,
# so bash never has to quote-balance an embedded program and payloads are never
# interpolated into source.
py() { docker run --rm -i --network "$NET" --entrypoint python3 "$SCRATCH" -q - "$@"; }

# A broken endpoint must never read as "nothing found" -> false PASS.
is_err()     { case "$1" in ERR:*) return 0;; *) return 1;; esac; }
has()        { case " $1 " in *" $2 "*) return 0;; *) return 1;; esac; }
has_choice() { case "$1" in *'"choices"'*) return 0;; *) return 1;; esac; }

# Test payloads are BUILT, never written as literals: a miscounted hand-typed
# secret looks exactly like a broken recognizer.
rep()  { printf "%${2}s" '' | tr ' ' "$1"; }   # rep A 16 -> 16 A's
rstr() { printf "$1%.0s" $(seq "$2"); }        # rstr 4111 4 -> 16 digits

analyze() { py "$ANALYZER/analyze" "$1" <<'PY'
import json, sys, urllib.request, urllib.error
url, text = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, json.dumps({'text': text, 'language': 'en'}).encode(),
                             {'Content-Type': 'application/json'})
try:
    d = json.load(urllib.request.urlopen(req, timeout=60))
except urllib.error.HTTPError as e:
    print('ERR:%s:%s' % (e.code, e.read()[:300].decode('utf-8', 'replace')))
    raise SystemExit
except Exception as e:                    # DNS/reset while the container boots
    print('ERR:unreachable:%s' % e)
    raise SystemExit
res = d if isinstance(d, list) else d.get('results', [])
print(' '.join(x.get('entity_type', '') for x in res))
PY
}

analyze_raw() { py "$ANALYZER/analyze" "${1:-hi}" <<'PY'
import json, sys, urllib.request, urllib.error
url, text = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, json.dumps({'text': text, 'language': 'en'}).encode(),
                             {'Content-Type': 'application/json'})
try:
    print(json.dumps(json.load(urllib.request.urlopen(req, timeout=60)), indent=2))
except urllib.error.HTTPError as e:
    print('HTTP', e.code); print(e.read().decode('utf-8', 'replace'))
except Exception as e:
    print('unreachable:', e)
PY
}

entities() { py "$ANALYZER/supportedentities" <<'PY'
import json, sys, urllib.request, urllib.error
try:
    d = json.load(urllib.request.urlopen(sys.argv[1], timeout=60))
except urllib.error.HTTPError as e:
    print('HTTP', e.code); raise SystemExit
except Exception as e:
    print('unreachable:', e); raise SystemExit
for lang, ents in (d.items() if isinstance(d, dict) else [('en', d)]):
    print(lang + ':', ' '.join(ents))
PY
}

# The anonymizer does NOT call the analyzer: it requires analyzer_results in the
# request body. So the pipeline is exercised the way production does it --
# /analyze first, feed the span list into /anonymize.
anonymize() { py "$ANALYZER/analyze" "$ANONYMIZER/anonymize" "$1" <<'PY'
import json, sys, urllib.request, urllib.error
aurl, aurl2, text = sys.argv[1], sys.argv[2], sys.argv[3]
def post(url, body):
    req = urllib.request.Request(url, json.dumps(body).encode(),
                                 {'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=60))
try:
    d = post(aurl, {'text': text, 'language': 'en'})
    res = d if isinstance(d, list) else d.get('results', [])
    out = post(aurl2, {'text': text, 'analyzer_results': res,
                       'operators': {'DEFAULT': {'type': 'replace',
                                                 'new_value': '<X>'}}})
except urllib.error.HTTPError as e:
    print('ERR:%s:%s' % (e.code, e.read()[:300].decode('utf-8', 'replace')))
    raise SystemExit
except Exception as e:
    print('ERR:unreachable:%s' % e)
    raise SystemExit
print(out.get('text', '') if isinstance(out, dict) else out)
PY
}

anonymize_raw() { py "$ANALYZER/analyze" "$ANONYMIZER/anonymize" "${1:-hi}" <<'PY'
import json, sys, urllib.request, urllib.error
aurl, aurl2, text = sys.argv[1], sys.argv[2], sys.argv[3]
def post(url, body):
    req = urllib.request.Request(url, json.dumps(body).encode(),
                                 {'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=60))
try:
    d = post(aurl, {'text': text, 'language': 'en'})
    res = d if isinstance(d, list) else d.get('results', [])
    print(json.dumps(post(aurl2, {'text': text, 'analyzer_results': res,
                       'operators': {'DEFAULT': {'type': 'replace',
                                                 'new_value': '<X>'}}}), indent=2))
except urllib.error.HTTPError as e:
    print('HTTP', e.code)
    print(e.read().decode('utf-8', 'replace'))
PY
}

case "${1:-}" in
  --entities)   entities; exit 0 ;;
  --raw)        analyze_raw "${2:-}"; exit 0 ;;
  --anon-raw)   anonymize_raw "${2:-}"; exit 0 ;;
esac

# Presidio holds spaCy weights, so a recreate takes tens of seconds to accept
# traffic. Probe until /health answers instead of firing into a booting worker
# and reporting ten connection errors as recognizer failures.
wait_up() {  # $1 = name, $2 = url
  for _ in $(seq 1 60); do
    py "$2/health" </dev/null >/dev/null 2>&1 && return 0
    sleep 2
  done
  # Say why it is down -- an unreachable container and a broken recognizer look
  # identical from the outside otherwise.
  state=$(docker inspect -f '{{.State.Status}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}' \
            "${PRESIDIO_ANALYZER_CONTAINER_NAME:-presidio-analyzer}" 2>&1 | tail -1)
  bad "$1 reachable" "no answer from $2 after 120s [$state]"
  return 1
}
wait_up analyzer "$ANALYZER"    || { printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1; }
wait_up anonymizer "$ANONYMIZER" || printf '\nwarning: anonymizer not up, masking check will fail\n'

# ---------------------------------------------------------------- analyzer
head_ "presidio-analyzer"

ents=$(analyze "hello world, nothing to see")
if is_err "$ents"; then bad "analyzer reachable" "$ents"
elif [ -n "$ents" ]; then bad "benign text is clean" "got: $ents"
else ok "benign text is clean"; fi

AWS="AKIA$(rep A 16)"
GHP="ghp_$(rep a 36)"
GLP="glpat-$(rep a 20)"
SKOR="sk-or-v1-$(rstr 01234567 8)"
SLACK="xoxb-$(rep 1 10)-$(rep a 24)"
AGE="AGE-SECRET-KEY-1$(rep q 58)"
MAIL="a$(rep b 8)@example.com"
CARD="$(rstr 4111 4)"
SSN="my social security number is $(rstr 123 3)"  # rstr repeats the WHOLE string, so 123 x3 = 9 digits

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
    for mdl in 'protected/' 'raw/'; do
      case "$m" in
        *"\"model_name\":\"$mdl"*) ok "route $mdl* registered" ;;
        *)        bad "route $mdl* registered" "not in /model/info" ;;
      esac
    done
    # Test an actual route. "protected/ANY" is not a model -- the config
    # declares protected/*, raw/* and *, so a literal ANY 400s. An explicit
    # model wins: /model/info lists every route including ones whose upstream
    # is dead (gpt-5.2 returns empty), so auto-picking the first is unreliable.
    models=${TEST_MODEL:-${PROTECTED_MODEL:-}}
    if [ -z "$models" ]; then
      models=$(printf '%s' "$m" | tr ',' '\n' | grep -o '"model_name":"protected/[^"]*"' \
               | cut -d'"' -f4 | grep -Ev 'transcribe|whisper|tts|embed|image' | head -1)
    fi
    for mdl in $models; do
      # Guard attached to THIS model? /model/info is the only place that shows
      # the resolved guardrail list. A model missing from it is a routing alias
      # (protected/auto/best-free), not a missing guardrail -- it matches the
      # protected/* wildcard instead, so assert on the prefix that covers it.
      case "$m" in
        *"\"model_name\":\"$mdl\""*)
          case "$m" in
            *"\"model_name\":\"$mdl\""*"presidio-pii"*) ok "guardrail attached [$mdl]" ;;
            *) bad "guardrail attached [$mdl]" "listed, but presidio-pii not attached" ;;
          esac ;;
        *) case "$mdl" in
             protected/*) ok "guardrail via protected/* wildcard [$mdl]" ;;
             *)           bad "guardrail attached [$mdl]" "not in /model/info and not a protected/ alias" ;;
           esac ;;
      esac

      # post_call test: the model must INVENT the secret, never be handed it.
      # Echoing a key we put in the prompt is masked by pre_call, so it passes
      # even with post_call completely dead -- which is what hid the card leak.
      r=$(curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
        -d "{\"model\":\"$mdl\",\"messages\":[{\"role\":\"user\",\"content\":\"Invent a fake 16-digit visa test number and print only the digits.\"}],\"max_tokens\":60}" \
        "$LITELLM/v1/chat/completions")
      if ! has_choice "$r"; then
        bad "post_call masks generated card [$mdl]" "no choices: $(printf '%s' "$r" | cut -c1-200)"
      else
        # Only the assistant text can leak. A refusal, or a model that just
        # never produced digits, is a pass -- there is nothing to mask.
        c=$(content_of "$r")
        if leaked=$(printf '%s' "$c" | grep -oE '[0-9]{13,19}' | head -1) && [ -n "$leaked" ]; then
          bad "post_call masks generated card [$mdl]" "unmasked digit run in content: $leaked"
        else
          ok "post_call masks generated card [$mdl]"
          [ -z "$(printf '%s' "$c" | tr -d '[:space:]')" ] && \
            skip "  (model returned no text; masking not exercised)"
        fi
      fi
      [ "$VERBOSE" -eq 1 ] && printf '       %s\n' "$r"
    done
  else
    skip "litellm route tests (LITELLM_MASTER_KEY not set; export it or source .env)"
  fi
else
  skip "litellm not reachable at $LITELLM (HTTP $code)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
