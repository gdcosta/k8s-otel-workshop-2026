#!/usr/bin/env bash
# Asserts the end state of Foundational Workshop #2.
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
cnt(){ $SPLUNK search "$1" -earliest_time -15m -auth "$SPLUNK_AUTH" 2>/dev/null | tail -1 | tr -dc '0-9'; }

echo "Verifying Foundational Workshop #2 (WS_USER=$WS_USER)"; echo

# --- warm-up -----------------------------------------------------------------
# These checks read data the application only produces under traffic. With an
# idle app the only log lines are readiness probes, which carry no trace context
# and no errors — so generate a short burst rather than reporting a false
# failure. Not a substitute for the JMeter load test; just enough to assert on.
#
# BURST_START is also what lets the severity checks below scope themselves to
# events this script created, instead of a flat 15-minute lookback.
#
# Observed 2026-08-29: running this immediately after a fresh `helm install` or
# a fresh `kubectl apply` can trip the severity check below with a false
# failure — six services cold-starting at once means proportionally more
# startup noise (Eureka registration, Tomcat init) than the single-pod version
# ever produced in one window, and that noise carries no severity by design.
# It clears on a second run a minute later. Not a bug; don't chase it if the
# Collector and app have both just (re)started.
#
# /oups doesn't exist in the microservices topology — the fault-injection
# replacement (scaling a backend to zero) is separate load-generator work, not
# yet built. /owners/abc is a real, cheap substitute for THIS script's purposes:
# customers-service can't parse a non-numeric ID and returns a genuine 400,
# giving the severity checks below something other than flat INFO to see.
warmup(){
  BURST_START=$(date +%s)
  printf '  … generating a short burst of traffic\n'
  # Real bug caught during a full clean-instance run-through, 2026-08-31: hitting
  # only customers-service left the distinct-service.name check below with just
  # ~3 values in a 15-minute window (not the 4+ it expects), reading as a broken
  # promotion when it was really just this warmup's narrow scope. Touch four of
  # the six services directly — api-gateway and discovery-server both still show
  # up too, from routing and Eureka traffic these calls generate along the way.
  for _ in $(seq 1 15); do
    curl -s -o /dev/null --max-time 5 http://minikube:30000/api/customer/owners      || true
    curl -s -o /dev/null --max-time 5 http://minikube:30000/api/customer/owners/abc  || true
    curl -s -o /dev/null --max-time 5 http://minikube:30000/api/vet/vets             || true
    curl -s -o /dev/null --max-time 5 http://minikube:30000/api/visit/owners/1/pets/1/visits || true
  done
  printf '  … waiting %ss for ingest\n\n' "${WARMUP_WAIT:-50}"
  sleep "${WARMUP_WAIT:-50}"
}
[ "${SKIP_WARMUP:-0}" = "1" ] || warmup

$SPLUNK status >/dev/null 2>&1 && ok "Splunk Enterprise running" || no "Splunk not running" "$SPLUNK start"

# The Collector lives in its own otel namespace, not default — a bare
# `helm status`/`kubectl get pods` here would silently check the wrong
# (empty) namespace once the collector moved out of default.
helm status "${WS_USER}-k8s-ws" -n otel >/dev/null 2>&1 \
  && ok "helm release ${WS_USER}-k8s-ws deployed" || no "release missing" "helm install ... --namespace otel --create-namespace"

for d in agent k8s-cluster-receiver; do
  kubectl get pods -n otel 2>/dev/null | grep -q "${WS_USER}-k8s-ws-splunk-otel-collector-${d}.*Running" \
    && ok "collector ${d} pod Running" || no "collector ${d} not Running" "kubectl get pods -n otel"
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

# Each of the six services should report its own service.name — that's the
# extraAttributes.fromLabels promotion, not an OTTL statement. Fewer than 4
# distinct names in a 15-minute window usually means only the idle services
# (config-server, discovery-server) have logged anything yet; run the warm-up
# traffic again rather than assuming it's broken.
n=$(cnt '| tstats count where index=k8s_ws_petclinic_logs by service.name | stats dc(service.name) as n')
[ "${n:-0}" -ge 4 ] && ok "$n distinct service.name values seen — per-service labelling works" \
  || no "only $n distinct service.name value(s)" "check extraAttributes.fromLabels for app.kubernetes.io/name -> service.name"

# --- access logging (step 6) -------------------------------------------------
# Only customers-service has Tomcat access logging enabled — see step 6 — so
# scope explicitly rather than searching the whole petclinic index.
n=$(cnt 'index=k8s_ws_petclinic_logs service.name="customers-service" http_status=* | stats count')
[ "${n:-0}" -gt 0 ] \
  && ok "access logs flowing and parsed ($n events/15m)" \
  || no "no http_status field on customers-service" "enable SERVER_TOMCAT_ACCESSLOG_* on customers-service (step 6)"

for f in http_method http_path http_duration_us; do
  n=$(cnt "index=k8s_ws_petclinic_logs service.name=\"customers-service\" $f=* | stats count")
  [ "${n:-0}" -gt 0 ] && ok "$f extracted" \
    || no "$f not extracted" "check the access-log ExtractPatterns regex (step 11)"
done

# --- severity (step 11) ------------------------------------------------------
# `severity` is written at INGEST by the OTTL transform, so an event keeps
# whatever it was given when it was indexed — for ever. A flat 15-minute
# lookback therefore reports a CORRECT configuration as broken for the first
# quarter of an hour after the fix, with a number that keeps changing.
# Scope these checks to the traffic this script generated a moment ago.
if [ -n "${BURST_START:-}" ]; then
  SEV_AGE=$(( $(date +%s) - BURST_START + 15 ))
  SEV_EARLIEST="-${SEV_AGE}s"
  SEV_WINDOW_NOTE="scoped to the last ${SEV_AGE}s — only the traffic this script just generated"
else
  SEV_EARLIEST="-15m"
  SEV_WINDOW_NOTE="last 15m: this INCLUDES events indexed before your most recent change"
fi
printf '  … severity checks: %s\n' "$SEV_WINDOW_NOTE"

scnt(){ $SPLUNK search "$1" -earliest_time "$SEV_EARLIEST" -auth "$SPLUNK_AUTH" 2>/dev/null | tail -1 | tr -dc '0-9'; }

# The classic failure is setting an ATTRIBUTE named severity holding high/low,
# which leaves Observability Cloud showing UNKNOWN. The other — far more common
# — failure is having no `severity` field at all, because the transform sets
# log.severity_text but never mirrors it to an attribute:
#     set(log.attributes["severity"], log.severity_text) where log.severity_text != nil
# severity_text drives Observability Cloud; the mirrored attribute is what makes
# it searchable as `severity` in Splunk. Both statements are needed.
MIRROR_HINT='the transform needs BOTH: set(log.severity_text, ...) for Observability Cloud AND set(log.attributes["severity"], log.severity_text) so it is searchable in Splunk — see step 11'

sev=$($SPLUNK search 'index=k8s_ws_petclinic_logs | stats count by severity | fields severity' \
      -earliest_time "$SEV_EARLIEST" -auth "$SPLUNK_AUTH" 2>/dev/null | tr -d ' ' | grep -viE '^severity$|^-+$|^$' | tr '\n' ' ')
if echo "$sev" | grep -qiE 'high|low'; then
  no "severity has values: $sev" "you set an attribute holding a priority, not the log level — $MIRROR_HINT"
elif echo "$sev" | grep -qE 'ERROR|INFO|WARN'; then
  ok "severity populated (values: $sev)"
else
  no "severity empty or unexpected: '${sev:-none}'" "$MIRROR_HINT"
fi

# A `severity=""` test passes VACUOUSLY when the field does not exist at all —
# it reported "no events with blank severity" ✓ in exactly the broken state the
# two checks either side of it were failing on. isnull() gives a real signal.
tot=$(scnt 'index=k8s_ws_petclinic_logs | stats count')
nul=$(scnt 'index=k8s_ws_petclinic_logs | where isnull(severity) OR severity="" | stats count')
if [ "${tot:-0}" -eq 0 ]; then
  no "no petclinic log events in the window" "generate traffic (curl http://minikube:30000/api/customer/owners) and re-run"
elif [ "${nul:-0}" -eq 0 ]; then
  ok "every event carries a severity ($tot events checked)"
elif [ $(( nul * 100 / tot )) -lt 5 ]; then
  # A handful with no level is normal — container start-up lines are emitted
  # before the logging pattern applies. A broken transform gives 100%, not 2%.
  ok "$((tot-nul)) of $tot events carry a severity ($nul without — start-up lines, expected)"
else
  no "$nul of $tot events have no severity" "$MIRROR_HINT"
fi

n=$(scnt 'index=k8s_ws_petclinic_logs http_status=5* severity="ERROR" | stats count')
m=$(scnt 'index=k8s_ws_petclinic_logs http_status=5* | stats count')
if [ "${m:-0}" -gt 0 ]; then
  [ "${n:-0}" -eq "${m:-0}" ] && ok "every 5xx is severity=ERROR ($n)" \
    || no "$n of $m 5xx marked ERROR" "check the status-derived severity rules in step 11"
else
  ok "no 5xx in window (nothing to check)"
fi

if [ -z "${BURST_START:-}" ] && [ "$fail" -gt 0 ]; then
  printf '\n  \033[33mNote:\033[0m severity is written at ingest and these checks used a 15-minute\n'
  printf '  window, so events indexed before your last change are counted too. Re-run\n'
  printf '  without SKIP_WARMUP=1 (or narrow the window) before believing a failure here.\n'
fi

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mFW2 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1; fi
