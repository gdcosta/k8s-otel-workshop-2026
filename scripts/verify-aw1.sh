#!/usr/bin/env bash
# Asserts the end state of Advanced Workshop #1.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?export WS_USER=<your-username>}"
SPLUNK=${SPLUNK:-/opt/splunk/bin/splunk}

# The workshop ships fixed lab credentials (00-setup), so this no longer has to
# hard-fail on a variable no module ever mentions. Override it if you changed
# the admin password:  export SPLUNK_AUTH=admin:<your-password>
WORKSHOP_AUTH='admin:Workshop2026!'
SPLUNK_AUTH="${SPLUNK_AUTH:-$WORKSHOP_AUTH}"

pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }
num(){ $SPLUNK search "$1" -earliest_time -15m -auth "$SPLUNK_AUTH" 2>/dev/null | tail -1 | tr -dc '0-9'; }
mcount(){ num "| mcatalog values(metric_name) WHERE index=$1 | rename values(metric_name) as m | mvexpand m ${2:-} | stats count"; }

echo "Verifying Advanced Workshop #1 (WS_USER=$WS_USER)"; echo

kubectl logs deploy/${WS_USER}-petclinic-otel-deployment 2>/dev/null | grep -q 'VersionLogger' \
  && ok "Java agent attached ($(kubectl logs deploy/${WS_USER}-petclinic-otel-deployment 2>/dev/null | grep -o 'splunk-[0-9.]*-otel-[0-9.]*' | head -1))" \
  || no "Java agent not attached" "check -javaagent in the Dockerfile CMD"

ep=$(kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- env 2>/dev/null | grep '^OTEL_EXPORTER_OTLP_ENDPOINT=' | cut -d= -f2-)
if echo "$ep" | grep -qE 'http://[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:4317'; then ok "OTLP endpoint resolved to an IP ($ep)"
else no "OTLP endpoint is '${ep:-unset}'" "must be an IP from the downward API, not a hostname"; fi

n=$(mcount k8s_ws_metrics); [ "${n:-0}" -gt 50 ] \
  && ok "infrastructure metrics present ($n distinct)" || no "only ${n:-0} metrics in k8s_ws_metrics" "check metricsEnabled: true"

n=$(mcount k8s_ws_petclinic_metrics '| search m="jvm*"'); [ "${n:-0}" -ge 10 ] \
  && ok "JVM metrics routed to app index ($n jvm.* metrics)" \
  || no "only ${n:-0} jvm metrics in k8s_ws_petclinic_metrics" "check transform/app_metrics_index and service.name match"

n=$(num '| tstats count where index=k8s_ws_traces'); [ "${n:-0}" -gt 0 ] \
  && ok "traces landing in k8s_ws_traces ($n spans/15m)" \
  || no "k8s_ws_traces empty" "splunk.com/index overrides traces — add transform/traces_index"

n=$(num 'index=k8s_ws_traces trace_id=* | stats count'); [ "${n:-0}" -gt 0 ] \
  && ok "spans carry trace_id" || no "spans lack trace_id" "check the traces pipeline exporter"

n=$(num '| tstats count where index=k8s_ws_petclinic_logs'); [ "${n:-0}" -gt 0 ] \
  && ok "app logs still isolated ($n events/15m)" || no "no app logs" "FW2 routing regressed"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mAW1 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else printf '\033[31m%d of %d checks failed.\033[0m See docs/03-advanced-1 troubleshooting.\n' "$fail" "$((pass+fail))"; exit 1; fi
