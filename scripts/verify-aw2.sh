#!/usr/bin/env bash
# Asserts the end state of Advanced Workshop #2.
# NOTE: no `pipefail`. `cmd | grep -q` makes cmd exit 141 (SIGPIPE) when grep
# matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?export WS_USER=<your-username>}"
REALM=${REALM:-us1}
SPLUNK=${SPLUNK:-/opt/splunk/bin/splunk}
REPO_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)

# The workshop ships fixed lab credentials (00-setup), so the log-side checks no
# longer silently skip. Override if you changed the admin password:
#   export SPLUNK_AUTH=admin:<your-password>
# Set it to the empty string to skip the log-side checks deliberately.
WORKSHOP_AUTH='admin:Workshop2026!'
SPLUNK_AUTH="${SPLUNK_AUTH:-$WORKSHOP_AUTH}"

pass=0; fail=0; warn=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }
tbd(){ printf '  \033[33m•\033[0m %s\n' "$1"; warn=$((warn+1)); }

echo "Verifying Advanced Workshop #2 (WS_USER=$WS_USER, realm=$REALM)"; echo

# --- warm-up -----------------------------------------------------------------
# These checks read data the application only produces under traffic. With an
# idle app the only log lines are readiness probes, which carry no trace context
# and no errors — so generate a short burst rather than reporting a false
# failure. Not a substitute for the JMeter load test; just enough to assert on.
warmup(){
  printf '  … generating a short burst of traffic\n'
  # /oups doesn't exist any more — Phase 3 replaced it with an external fault
  # (kubectl scale deployment/visits-service --replicas=0, FW2 §8 / AW1 §1).
  # This warmup only needs real requests flowing, not a forced error.
  for _ in $(seq 1 20); do
    curl -s -o /dev/null --max-time 5 http://minikube:30000/                        || true
    curl -s -o /dev/null --max-time 5 http://minikube:30000/api/customer/owners     || true
    curl -s -o /dev/null --max-time 5 http://minikube:30000/api/vet/vets            || true
  done
  printf '  … waiting %ss for ingest\n\n' "${WARMUP_WAIT:-50}"
  sleep "${WARMUP_WAIT:-50}"
}
[ "${SKIP_WARMUP:-0}" = "1" ] || warmup

# --- ingest token ------------------------------------------------------------
if [ -r ~/.o11y-token ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "X-SF-Token: $(cat ~/.o11y-token)" -H 'Content-Type: application/json' \
    -d '[{"gauge":[{"metric":"workshop.verify","value":1}]}]' \
    "https://ingest.${REALM}.signalfx.com/v2/datapoint")
  [ "$code" = "200" ] && ok "ingest token accepted by realm $REALM" \
    || no "ingest returned HTTP $code" "401 = wrong token or realm"
else no "~/.o11y-token not found" "see step 1"; fi

# --- collector -> observability ---------------------------------------------
CM=$(kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
      -o go-template='{{index .data "relay"}}' 2>/dev/null)
echo "$CM" | grep -q 'signalfx' \
  && ok "collector has signalfx exporters" \
  || no "no signalfx exporter" "add splunkObservability to values-workshop.yaml"

n=$(kubectl logs daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent --tail=400 2>/dev/null \
    | grep -ciE '401|403|unauthorized')
[ "${n:-0}" -eq 0 ] && ok "no auth errors from the collector" \
  || no "$n auth errors in collector logs" "check the access token"

# --- profiling ---------------------------------------------------------------
# Set once, via instrumentation.spec.java.env in values-aw2.yaml — applies to
# every operator-instrumented pod uniformly, unlike the old per-Deployment env
# block. Checked per service, same minimum pair AW1 established
# (customers-service hand-built, vets-service pulled) to prove it's genuinely
# uniform rather than something that happened to land on one service.
for svc in customers-service vets-service; do
  pod=$(kubectl get pod -n petclinic -l app.kubernetes.io/name="$svc" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then no "$svc: no running pod found" "kubectl get pods -n petclinic"; continue; fi
  envout=$(kubectl get pod -n petclinic "$pod" \
    -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null)
  enabled=$(echo "$envout" | grep '^SPLUNK_PROFILER_ENABLED=' | cut -d= -f2-)
  proto=$(echo "$envout"   | grep '^SPLUNK_PROFILER_OTLP_PROTOCOL=' | cut -d= -f2-)
  ep=$(echo "$envout"      | grep '^OTEL_EXPORTER_OTLP_ENDPOINT=' | cut -d= -f2-)
  if [ "$enabled" = "true" ]; then
    if { [ "$proto" = "grpc" ] && echo "$ep" | grep -q ':4317'; } || \
       { [ "$proto" = "http/protobuf" ] && echo "$ep" | grep -q ':4318'; }; then
      ok "$svc: profiler enabled, protocol ($proto) matches endpoint"
    else
      no "$svc: profiler protocol '$proto' vs endpoint '$ep'" "set SPLUNK_PROFILER_OTLP_PROTOCOL to match in instrumentation.spec.java.env"
    fi
  else
    no "$svc: profiler not enabled" "add SPLUNK_PROFILER_ENABLED=true to instrumentation.spec.java.env in values-aw2.yaml"
  fi
done

# --- RUM ---------------------------------------------------------------------
# Grepping the served HTML proves NOTHING about RUM. The published snippet once
# carried a `#` comment inside the object literal — a SyntaxError in JavaScript.
# The page served both `o11y-gdi-rum` and `SplunkRum.init`, both greps passed,
# SplunkRum.init never ran and no RUM data was ever collected. So: load the page
# in a real browser and assert the global exists; if that is impossible, at
# least prove the init block PARSES rather than merely being present.
html=$(curl -s --max-time 20 http://minikube:30000/ 2>/dev/null)
echo "$html" | grep -q 'o11y-gdi-rum'  && ok "RUM library served in page" \
  || no "RUM script tag missing" "run scripts/inject-rum-snippet.sh (step 7) — api-gateway is a pulled image, there is no layout.html to hand-edit here"

# The init call, from `SplunkRum.init(` to its closing `});`.
init_block=$(printf '%s\n' "$html" | tr -d '\r' | sed -n '/SplunkRum\.init(/,/});/p')

rum_static_check(){
  if [ -z "$init_block" ]; then
    no "SplunkRum.init missing from the page" "snippet incomplete — see step 7"
    return
  fi
  if command -v node >/dev/null 2>&1; then
    tmp=$(mktemp /tmp/rum-init.XXXXXX.js) || { tbd "could not write a temp file — RUM snippet not validated"; return; }
    printf '%s\n' "$init_block" > "$tmp"
    if node --check "$tmp" >/dev/null 2>&1; then
      ok "SplunkRum.init block parses as valid JavaScript (node --check)"
    else
      no "SplunkRum.init block is NOT valid JavaScript" \
         "it is served, but the browser cannot run it — node --check says: $(node --check "$tmp" 2>&1 | head -2 | tr '\n' ' ')"
    fi
    rm -f "$tmp"
    return
  fi
  # No node, no browser: catch the two failure modes seen in the wild —
  # a `#` comment (SyntaxError), and a property line with no trailing comma.
  if printf '%s' "$init_block" | grep -q '#'; then
    no "SplunkRum.init contains a '#' comment" \
       "'#' is not a JavaScript comment — it is a SyntaxError, and RUM never initialises. Use // or move the note to prose (step 7)"
  elif [ "$(printf '%s\n' "$init_block" | grep -E '^[[:space:]]*[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*:' \
            | sed '$d' | grep -cvE ',[[:space:]]*$')" -gt 0 ]; then
    no "SplunkRum.init has a property with no trailing comma" \
       "the object literal is malformed and will not parse — compare against the snippet in step 7"
  else
    tbd "SplunkRum.init present and structurally plausible — install Playwright (step 7) to prove it actually initialises"
  fi
}

PW_PY=""
for c in ~/playwright-venv/bin/python ~/playwright-venv/bin/python3; do
  [ -x "$c" ] && { PW_PY=$c; break; }
done
RUM_SCRIPT=""
for c in "${RUM_TEST:-}" "${REPO_DIR:-.}/labs/rum/petclinic_browser_test.py" \
         ~/k8s-otel-workshop/labs/rum/petclinic_browser_test.py \
         ~/labs/rum/petclinic_browser_test.py ~/petclinic_browser_test.py; do
  [ -n "$c" ] && [ -r "$c" ] && { RUM_SCRIPT=$c; break; }
done

if [ -n "$PW_PY" ] && [ -n "$RUM_SCRIPT" ]; then
  # --iterations 0 loads the page, asserts `typeof SplunkRum !== "undefined"`
  # in the browser, and exits — the whole journey is not needed here.
  pw_out=$("$PW_PY" "$RUM_SCRIPT" --url http://minikube:30000 --iterations 0 2>&1); pw_rc=$?
  if printf '%s' "$pw_out" | grep -q 'SplunkRum is initialised'; then
    ok "SplunkRum initialised in a real browser (Playwright)"
  elif printf '%s' "$pw_out" | grep -q 'SplunkRum is NOT defined'; then
    no "SplunkRum is not defined in the browser" \
       "the snippet is served but does not run — check it is valid JavaScript ('#' is not a comment) and that the RUM library loaded (step 7)"
  else
    tbd "could not drive the browser (exit $pw_rc): $(printf '%s' "$pw_out" | tail -2 | tr '\n' ' ')"
    rum_static_check
  fi
else
  [ -n "$PW_PY" ] || tbd "playwright venv not found — RUM needs a real browser to verify (step 7)"
  [ -n "$RUM_SCRIPT" ] || tbd "labs/rum/petclinic_browser_test.py not found — set RUM_TEST=/path/to/it"
  rum_static_check
fi

# --- Related Content correlation fields --------------------------------------
# APM<->Logs joins on host.name, service.name, deployment.environment and
# trace_id. All four must be on the LOG, and match the span exactly. Checked
# per service — service.name now genuinely differs per service (FW2's label
# promotion), so a single hardcoded expectation can't cover this any more.
lq(){ $SPLUNK search "$1" -earliest_time -15m -auth "${SPLUNK_AUTH:-}" 2>/dev/null | tail -1 | tr -d ' '; }

if [ -n "${SPLUNK_AUTH:-}" ]; then
  n=$(lq 'index=k8s_ws_petclinic_logs trace_id=* | stats count' | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && ok "logs carry trace_id ($n events/15m)" \
    || no "no trace_id on logs" "check LOGGING_PATTERN_LEVEL in instrumentation.spec.java.env (step 5)"

  for svc in customers-service vets-service; do
    pod=$(kubectl get pod -n petclinic -l app.kubernetes.io/name="$svc" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$pod" ]; then no "$svc: no running pod found" "kubectl get pods -n petclinic"; continue; fi
    envout=$(kubectl get pod -n petclinic "$pod" \
      -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' 2>/dev/null)
    SP_SVC=$(echo "$envout" | grep '^OTEL_SERVICE_NAME=' | cut -d= -f2-)
    # deployment.environment is NOT in this pod's own env — it's added
    # collector-side by transform/traces_index (values-aw2.yaml), not by the
    # operator. Real bug caught live: grepping OTEL_RESOURCE_ATTRIBUTES for it
    # here always came back empty, because it's simply never there — that
    # attribute name doesn't appear in the pod's env under either semconv
    # spelling. Ask the span itself what it actually carries instead of
    # trying to derive the expectation from the pod.
    SP_ENV=$(lq "index=k8s_ws_traces \"service.name\"=\"$svc\" | rename \"deployment.environment\" as x | search x=* | head 1 | table x")

    lsvc=$(lq "index=k8s_ws_petclinic_logs \"service.name\"=\"$svc\" | rename \"service.name\" as x | head 1 | table x")
    [ -n "$lsvc" ] && [ "$lsvc" = "$SP_SVC" ] \
      && ok "$svc: log service.name matches the span ($lsvc)" \
      || no "$svc: log service.name='${lsvc:-missing}' vs span='${SP_SVC}'" "they must match exactly (step 5)"

    lenv=$(lq "index=k8s_ws_petclinic_logs \"service.name\"=\"$svc\" | rename \"deployment.environment\" as x | search x=* | head 1 | table x")
    [ -n "$lenv" ] && [ "$lenv" = "$SP_ENV" ] \
      && ok "$svc: log deployment.environment matches the span ($lenv)" \
      || no "$svc: log env='${lenv:-missing}' vs span='${SP_ENV}'" "APM identifies a service as (name, environment) — check transform/traces_index sets deployment.environment too (values-aw2.yaml)"
  done

  lhost=$(lq 'index=k8s_ws_petclinic_logs | head 1 | table host')
  [ -n "$lhost" ] && ok "logs carry host ($lhost — aliased to host.name)" \
    || no "no host field" "check resource detection"

  # the join has to actually resolve, not merely look plausible
  tid=$(lq 'index=k8s_ws_petclinic_logs trace_id=* | head 1 | table trace_id' | tr -dc '0-9a-f')
  if [ -n "$tid" ]; then
    n=$(lq "index=k8s_ws_traces \"$tid\" | stats count" | tr -dc '0-9')
    [ "${n:-0}" -gt 0 ] \
      && ok "a log trace_id resolves to a span (${tid:0:16}…)" \
      || no "trace_id ${tid:0:16}… has no matching span" "logs and traces may cover different windows"
  fi
else
  tbd "SPLUNK_AUTH explicitly empty — skipped Related Content field checks"
fi

# --- Log Observer Connect (Splunk side) --------------------------------------
if $SPLUNK btool authorize list role_loc_service >/dev/null 2>&1; then
  cfg=$($SPLUNK btool authorize list role_loc_service 2>/dev/null)
  echo "$cfg" | grep -q 'indexes_list_all = disabled' \
    && ok "loc_service: indexes_list_all disabled (current guidance)" \
    || no "indexes_list_all not disabled" "current docs require it disabled"
  echo "$cfg" | grep -q 'importRoles' \
    && no "loc_service has importRoles" "it unions srchIndexesAllowed — remove it" \
    || ok "loc_service has no importRoles (least privilege)"
  echo "$cfg" | grep -q 'edit_tokens_own = enabled' \
    && ok "edit_tokens_own enabled" || no "edit_tokens_own missing" "LOC mints its own token"
else tbd "role_loc_service not found — Log Observer Connect not configured"; fi

echo
tot=$((pass+fail))
if [ "$fail" -eq 0 ]; then
  printf '\033[32mAW2 complete — %d/%d checks passed.\033[0m' "$pass" "$tot"
  [ "$warn" -gt 0 ] && printf ' (%d optional not configured)' "$warn"; echo
else
  printf '\033[31m%d of %d checks failed.\033[0m See docs/04-advanced-2 troubleshooting.\n' "$fail" "$tot"; exit 1
fi
