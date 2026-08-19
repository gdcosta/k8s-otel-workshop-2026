#!/usr/bin/env bash
# Asserts the end state of Foundational Workshop #2.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?export WS_USER=<your-username>}"
SPLUNK=${SPLUNK:-/opt/splunk/bin/splunk}
: "${SPLUNK_AUTH:?export SPLUNK_AUTH=admin:<password>}"

pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }
cnt(){ $SPLUNK search "$1" -earliest_time -15m -auth "$SPLUNK_AUTH" 2>/dev/null | tail -1 | tr -dc '0-9'; }

echo "Verifying Foundational Workshop #2 (WS_USER=$WS_USER)"; echo

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

$SPLUNK status >/dev/null 2>&1 && ok "Splunk Enterprise running" || no "Splunk not running" "$SPLUNK start"

helm status "${WS_USER}-k8s-ws" >/dev/null 2>&1 \
  && ok "helm release ${WS_USER}-k8s-ws deployed" || no "release missing" "helm install ..."

for d in agent k8s-cluster-receiver; do
  kubectl get pods 2>/dev/null | grep -q "${WS_USER}-k8s-ws-splunk-otel-collector-${d}.*Running" \
    && ok "collector ${d} pod Running" || no "collector ${d} not Running" "kubectl get pods"
done

n=$(cnt '| tstats count where index=k8s_ws_logs')
[ "${n:-0}" -gt 0 ] && ok "k8s_ws_logs receiving data ($n events/15m)" \
  || no "no data in k8s_ws_logs" "check HEC SSL is disabled; curl the HEC endpoint directly"

n=$(cnt '| tstats count where index=k8s_ws_logs sourcetype="kube:container:kube-apiserver"')
[ "${n:-0}" -gt 0 ] && ok "audit log flowing ($n events/15m)" \
  || no "no audit events" "re-check FW1 audit policy"

n=$(cnt '| tstats count where index=k8s_ws_petclinic_logs')
[ "${n:-0}" -gt 0 ] && ok "annotation index routing works ($n events/15m)" \
  || no "k8s_ws_petclinic_logs empty" "check splunk.com/index annotation on the POD TEMPLATE"

n=$(cnt "| tstats count where index=k8s_ws_petclinic_logs sourcetype=\"petclinic:app:log\"")
[ "${n:-0}" -gt 0 ] && ok "OTTL transform applied ($n events/15m)" \
  || no "sourcetype not rewritten" "OTTL needs context-prefixed paths — see step 11"

# --- access logging (step 7) -------------------------------------------------
n=$(cnt 'index=k8s_ws_petclinic_logs http_status=* | stats count')
[ "${n:-0}" -gt 0 ] \
  && ok "access logs flowing and parsed ($n events/15m)" \
  || no "no http_status field" "enable SERVER_TOMCAT_ACCESSLOG_* on the Deployment (step 7)"

for f in http_method http_path http_duration_us; do
  n=$(cnt "index=k8s_ws_petclinic_logs $f=* | stats count")
  [ "${n:-0}" -gt 0 ] && ok "$f extracted" \
    || no "$f not extracted" "check the access-log ExtractPatterns regex (step 11)"
done

# --- severity (step 11) ------------------------------------------------------
# The classic failure is setting an ATTRIBUTE named severity, which yields
# values like high/low and leaves Observability Cloud showing UNKNOWN.
sev=$($SPLUNK search 'index=k8s_ws_petclinic_logs | stats count by severity | fields severity' \
      -earliest_time -15m -auth "$SPLUNK_AUTH" 2>/dev/null | tr -d ' ' | grep -viE '^severity$|^-+$|^$' | tr '\n' ' ')
if echo "$sev" | grep -qiE 'high|low'; then
  no "severity has values: $sev" "you set an attribute, not log.severity_text — see step 11"
elif echo "$sev" | grep -qE 'ERROR|INFO|WARN'; then
  ok "severity_text populated (values: $sev)"
else
  no "severity empty or unexpected: '${sev:-none}'" "set log.severity_text, not an attribute"
fi

n=$(cnt 'index=k8s_ws_petclinic_logs severity="" | stats count')
[ "${n:-0}" -eq 0 ] && ok "no events with blank severity" \
  || no "$n events have blank severity" "severity_text defaults to \"\", not nil — test log_level instead"

n=$(cnt 'index=k8s_ws_petclinic_logs http_status=5* severity="ERROR" | stats count')
m=$(cnt 'index=k8s_ws_petclinic_logs http_status=5* | stats count')
if [ "${m:-0}" -gt 0 ]; then
  [ "${n:-0}" -eq "${m:-0}" ] && ok "every 5xx is severity=ERROR ($n)" \
    || no "$n of $m 5xx marked ERROR" "check the status-derived severity rules"
else
  ok "no 5xx in window (nothing to check)"
fi

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mFW2 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1; fi
