#!/usr/bin/env bash
# Asserts the end state of Advanced Workshop #1.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?export WS_USER=<your-username>}"
SPLUNK=${SPLUNK:-/opt/splunk/bin/splunk}
RELEASE="${WS_USER}-k8s-ws"
# The Collector/operator live in their own namespace, not default — see the
# real 2026-08-31 incident this whole Helm-status check exists for.
OTEL_NS=${OTEL_NS:-otel}

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

# --- Helm release health (checked first — every check below assumes this) ---
# Real incident, 2026-08-31: a field-manager conflict left this release stuck
# in STATUS=failed for hours while individual resources were patched around
# it by hand. Every live signal looked healthy (spans flowing, zero export
# failures) because the RUNNING resources were fine — what silently drifted
# was the collector's own OTTL config, stuck on an older revision's content
# that was missing a real statement (see values-final.yaml's git history). No
# check below would have caught the cause, only a downstream symptom of it —
# this one catches it directly, first, before chasing anything else.
hs=$(helm status "$RELEASE" -n "$OTEL_NS" -o json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null)
[ "$hs" = "deployed" ] \
  && ok "Helm release '$RELEASE' is deployed (not failed/pending)" \
  || no "Helm release status is '${hs:-unknown}', not deployed" "run 'helm history $RELEASE -n $OTEL_NS' to see what failed and why; a field-manager conflict on the Instrumentation CR usually means deleting and letting the next 'helm upgrade' recreate it cleanly — see AGENTS.md's Phase 4c notes for the exact incident this check exists for"

# --- Operator infrastructure ---------------------------------------------
kubectl get pod -n "$OTEL_NS" -l app.kubernetes.io/name=operator 2>/dev/null \
  | grep -q '1/1.*Running' \
  && ok "OpenTelemetry Operator pod healthy" \
  || no "operator pod not Running/Ready" "check operator.enabled + operatorcrds.install: true, and that the webhook race didn't strand the first install — see step 3's troubleshooting"

kubectl get instrumentation -n "$OTEL_NS" "${RELEASE}-splunk-otel-collector" >/dev/null 2>&1 \
  && ok "Instrumentation CR present (${RELEASE}-splunk-otel-collector)" \
  || no "Instrumentation CR missing" "instrumentation.enabled must be true in values-aw1.yaml"

# --- Auto-instrumentation actually injected, on all six services — both
#     the one hand-built image and the five pulled ones alike, which is the
#     whole point of using the operator instead of a hand-built Dockerfile.
for svc in customers-service vets-service visits-service api-gateway discovery-server config-server; do
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

n=$(num 'index=k8s_ws_traces | stats dc("service.name") as c | fields c'); \
[ "${n:-0}" -ge 6 ] \
  && ok "spans carry the per-service service.name the agent reports ($n distinct)" \
  || no "only $n distinct service.name values on spans, expected 6" "the operator sets OTEL_SERVICE_NAME per Deployment automatically — check step 3's checkpoint, and that every Deployment carries the inject-java annotation"

# PetClinic's own bundled Zipkin auto-export (Spring Boot Actuator,
# unrelated to the OTel Java agent) tries and fails to reach localhost:9411
# unless SPRING_AUTOCONFIGURE_EXCLUDE disables it — see values-aw1.yaml's
# comment for the two fixes that looked plausible and didn't work before
# this one. A handful of leftover spans from before the fix landed is fine;
# a large, steady count means the exclude isn't actually reaching the pods.
n=$(num 'index=k8s_ws_traces earliest=-5m "attributes.server.address"=localhost "attributes.server.port"=9411 | stats count'); \
[ "${n:-0}" -lt 5 ] \
  && ok "no meaningful localhost:9411 Zipkin noise ($n spans/5m)" \
  || no "$n localhost:9411 spans in the last 5 minutes" "check SPRING_AUTOCONFIGURE_EXCLUDE is in instrumentation.spec.java.env and reached the running pods (kubectl rollout restart if you just added it)"

# Every service's own spring.config.import briefly tries http://localhost:8888
# at startup before succeeding against the real config-server — restart-only,
# not continuous like the Zipkin noise above, so this checks a wider window.
# Unlike the Zipkin check, CONFIG_SERVER_URL fixes this to exactly zero, ever
# — any count here at all means the fix hasn't reached the running pods.
n=$(num 'index=k8s_ws_traces earliest=-60m "attributes.server.address"=localhost "attributes.server.port"=8888 | stats count'); \
[ "${n:-0}" -eq 0 ] \
  && ok "no localhost:8888 config-client noise (0 spans/60m)" \
  || no "$n localhost:8888 spans in the last 60 minutes" "check CONFIG_SERVER_URL is in instrumentation.spec.java.env and reached the running pods (kubectl rollout restart if you just added it)"

n=$(num '| tstats count where index=k8s_ws_petclinic_logs'); [ "${n:-0}" -gt 0 ] \
  && ok "app logs still isolated ($n events/15m)" || no "no app logs" "FW2 routing regressed"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mAW1 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else printf '\033[31m%d of %d checks failed.\033[0m See docs/03-advanced-1 troubleshooting.\n' "$fail" "$((pass+fail))"; exit 1; fi
