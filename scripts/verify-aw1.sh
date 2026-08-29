#!/usr/bin/env bash
# Asserts the end state of Advanced Workshop #1.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?export WS_USER=<your-username>}"
SPLUNK=${SPLUNK:-/opt/splunk/bin/splunk}
RELEASE="${WS_USER}-k8s-ws"

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

# --- Operator infrastructure ---------------------------------------------
kubectl get pod -n default -l app.kubernetes.io/name=operator 2>/dev/null \
  | grep -q '1/1.*Running' \
  && ok "OpenTelemetry Operator pod healthy" \
  || no "operator pod not Running/Ready" "check operator.enabled + operatorcrds.install: true, and that the webhook race didn't strand the first install — see step 3's troubleshooting"

kubectl get instrumentation -n default "${RELEASE}-splunk-otel-collector" >/dev/null 2>&1 \
  && ok "Instrumentation CR present (${RELEASE}-splunk-otel-collector)" \
  || no "Instrumentation CR missing" "instrumentation.enabled must be true in values-aw1.yaml"

# --- Auto-instrumentation actually injected, on BOTH a hand-built and a
#     pulled image — the whole point of using the operator instead of a
#     hand-built Dockerfile is that it doesn't care which one it is.
for svc in customers-service vets-service; do
  pod=$(kubectl get pod -n petclinic -l app.kubernetes.io/name="$svc" \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$pod" ]; then
    no "$svc: no running pod found" "kubectl get pods -n petclinic"
    continue
  fi
  if kubectl get pod -n petclinic "$pod" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null \
       | grep -q 'opentelemetry-auto-instrumentation-java'; then
    ok "$svc: Java agent injected (init container present)"
  else
    no "$svc: no opentelemetry-auto-instrumentation-java init container" \
       "confirm the inject-java annotation is on this Deployment's pod template — step 3"
  fi
done

# --- Signals actually flowing --------------------------------------------
n=$(mcount k8s_ws_metrics); [ "${n:-0}" -gt 50 ] \
  && ok "infrastructure metrics present ($n distinct)" || no "only ${n:-0} metrics in k8s_ws_metrics" "check metricsEnabled: true"

n=$(mcount k8s_ws_petclinic_metrics '| search m="jvm*"'); [ "${n:-0}" -ge 10 ] \
  && ok "JVM metrics routed to app index ($n jvm.* metrics)" \
  || no "only ${n:-0} jvm metrics in k8s_ws_petclinic_metrics" "check transform/app_metrics_index — its predicate is k8s.namespace.name == petclinic, not a service name"

n=$(num '| tstats count where index=k8s_ws_traces'); [ "${n:-0}" -gt 0 ] \
  && ok "traces landing in k8s_ws_traces ($n spans/15m)" \
  || no "k8s_ws_traces empty" "splunk.com/index overrides traces onto k8s_ws_petclinic_logs unless transform/traces_index is present — see step 5"

n=$(num 'index=k8s_ws_traces trace_id=* | stats count'); [ "${n:-0}" -gt 0 ] \
  && ok "spans carry trace_id" || no "spans lack trace_id" "check the traces pipeline exporter"

n=$(num 'index=k8s_ws_traces "service.name"=customers-service OR "service.name"=vets-service | stats dc("service.name") as c | fields c'); \
[ "${n:-0}" -ge 1 ] \
  && ok "spans carry the per-service service.name the agent reports ($n distinct)" \
  || no "no per-service service.name found on spans" "the operator sets OTEL_SERVICE_NAME per Deployment automatically — check step 3's checkpoint"

n=$(num '| tstats count where index=k8s_ws_petclinic_logs'); [ "${n:-0}" -gt 0 ] \
  && ok "app logs still isolated ($n events/15m)" || no "no app logs" "FW2 routing regressed"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mAW1 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else printf '\033[31m%d of %d checks failed.\033[0m See docs/03-advanced-1 troubleshooting.\n' "$fail" "$((pass+fail))"; exit 1; fi
