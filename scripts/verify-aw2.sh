#!/usr/bin/env bash
# Asserts the end state of Advanced Workshop #2.
# NOTE: no `pipefail`. `cmd | grep -q` makes cmd exit 141 (SIGPIPE) when grep
# matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?export WS_USER=<your-username>}"
# SPLUNK_AUTH is optional here; without it the log-side checks are skipped.
REALM=${REALM:-us1}
SPLUNK=${SPLUNK:-/opt/splunk/bin/splunk}

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
  for _ in $(seq 1 20); do
    curl -s -o /dev/null --max-time 5 http://minikube:30000/          || true
    curl -s -o /dev/null --max-time 5 http://minikube:30000/oups      || true
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
PL=$(kubectl logs deploy/${WS_USER}-petclinic-otel-deployment 2>/dev/null | grep -A8 'Profiler configuration')
if echo "$PL" | grep -q 'Enabled : true'; then
  proto=$(echo "$PL" | grep OtlpProtocol | awk '{print $NF}')
  ep=$(kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- \
       printenv OTEL_EXPORTER_OTLP_ENDPOINT 2>/dev/null)
  if { [ "$proto" = "grpc" ] && echo "$ep" | grep -q ':4317'; } || \
     { [ "$proto" = "http/protobuf" ] && echo "$ep" | grep -q ':4318'; }; then
    ok "profiler enabled, protocol ($proto) matches endpoint"
  else
    no "profiler protocol '$proto' vs endpoint '$ep'" "set SPLUNK_PROFILER_OTLP_PROTOCOL to match"
  fi
else no "profiler not enabled" "set SPLUNK_PROFILER_ENABLED=true on the Deployment"; fi

# --- RUM ---------------------------------------------------------------------
html=$(curl -s --max-time 20 http://minikube:30000/ 2>/dev/null)
echo "$html" | grep -q 'o11y-gdi-rum'  && ok "RUM library served in page" \
  || no "RUM script tag missing" "re-check layout.html and rebuild the image"
echo "$html" | grep -q 'SplunkRum.init' && ok "SplunkRum.init present" \
  || no "SplunkRum.init missing" "snippet incomplete"

[ -x ~/playwright-venv/bin/playwright ] && ok "playwright installed" \
  || tbd "playwright not installed — RUM needs a real browser"

# --- Related Content correlation fields --------------------------------------
# APM<->Logs joins on host.name, service.name, deployment.environment and
# trace_id. All four must be on the LOG, and match the span exactly.
SP_SVC=$(kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- \
         printenv OTEL_SERVICE_NAME 2>/dev/null)
SP_ENV=$(kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- \
         printenv OTEL_RESOURCE_ATTRIBUTES 2>/dev/null | sed 's/.*deployment.environment=//; s/,.*//')

lq(){ $SPLUNK search "$1" -earliest_time -15m -auth "${SPLUNK_AUTH:-}" 2>/dev/null | tail -1 | tr -d ' '; }

if [ -n "${SPLUNK_AUTH:-}" ]; then
  n=$(lq 'index=k8s_ws_petclinic_logs trace_id=* | stats count' | tr -dc '0-9')
  [ "${n:-0}" -gt 0 ] && ok "logs carry trace_id ($n events/15m)" \
    || no "no trace_id on logs" "add LOGGING_PATTERN_LEVEL to the Deployment (step 5)"

  lsvc=$(lq 'index=k8s_ws_petclinic_logs | rename "service.name" as x | search x=* | head 1 | table x')
  [ -n "$lsvc" ] && [ "$lsvc" = "$SP_SVC" ] \
    && ok "log service.name matches the span ($lsvc)" \
    || no "log service.name='${lsvc:-missing}' vs span='${SP_SVC}'" "they must match exactly (step 5)"

  lenv=$(lq 'index=k8s_ws_petclinic_logs | rename "deployment.environment" as x | search x=* | head 1 | table x')
  [ -n "$lenv" ] && [ "$lenv" = "$SP_ENV" ] \
    && ok "log deployment.environment matches the span ($lenv)" \
    || no "log env='${lenv:-missing}' vs span='${SP_ENV}'" "APM identifies a service as (name, environment)"

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
  tbd "SPLUNK_AUTH not set — skipped Related Content field checks"
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
