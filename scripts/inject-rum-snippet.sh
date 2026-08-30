#!/usr/bin/env bash
# Injects the Splunk RUM (splunk-otel-web) snippet into the AngularJS SPA
# api-gateway serves, without rebuilding an image.
#
# WHY THIS EXISTS: the old (pre-microservices) approach edited
# src/main/resources/templates/fragments/layout.html by hand and rebuilt the
# monolith's own image — that only worked because the monolith was built from
# source here. api-gateway is a PULLED image in this topology (like five of
# the six PetClinic services — see AGENTS.md's Phase 4a notes on why the same
# constraint forced AW1's Java-agent attach to move off a hand-built
# Dockerfile). There is no Dockerfile to edit for api-gateway either.
#
# Instead: pull the page api-gateway is ACTUALLY serving right now, insert the
# snippet, and mount the result over the one file that matters via a ConfigMap
# + subPath volumeMount. The served file is never copied into this repo as a
# static asset — it's a pulled image's content, and treating a snapshot of it
# as something this repo owns would silently drift the moment the image tag
# changes. This script always re-extracts the live page first.
#
# Verified live 2026-08-29: api-gateway's index.html lives at
# /application/BOOT-INF/classes/static/index.html (Paketo buildpacks layout,
# not a plain jar) — that exact path is where the subPath mount lands.
#
# Usage:
#   WS_USER=<you> REALM=us1 RUM_TOKEN=$(cat ~/.rum-token) \
#     ./scripts/inject-rum-snippet.sh
#
# Idempotent — safe to re-run (skips re-injection if the snippet is already
# present in the currently-served page; re-patches the Deployment either way,
# which is a no-op if nothing changed).
set -euo pipefail

: "${WS_USER:?export WS_USER=<your-username>}"
REALM="${REALM:-us1}"
APP_URL="${APP_URL:-http://minikube:30000}"
NAMESPACE="${NAMESPACE:-petclinic}"
DEPLOYMENT="${DEPLOYMENT:-api-gateway}"
CM_NAME="${CM_NAME:-petclinic-rum-index}"
# Not WS_USER-prefixed — same reasoning as the six Service names in
# labs/manifests/petclinic-microservices*.yml: this ConfigMap never leaves a
# single participant's own single-node minikube cluster, so there is no
# shared surface for two participants' names to collide on.

if [ -z "${RUM_TOKEN:-}" ]; then
  if [ -r ~/.rum-token ]; then RUM_TOKEN=$(cat ~/.rum-token)
  else echo "RUM_TOKEN not set and ~/.rum-token not found — see AW2 step 1" >&2; exit 1
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "→ pulling the page api-gateway is serving right now ($APP_URL/)"
curl -fsSL --max-time 20 "$APP_URL/" -o "$WORK/index.html"

if grep -q 'SplunkRum.init' "$WORK/index.html"; then
  echo "→ snippet already present in the currently-served page — nothing to inject"
  echo "  (if you changed RUM_TOKEN/REALM, roll the deployment to fetch fresh from the"
  echo "  pod: the extracted page reflects whatever's already mounted, not a fresh pull)"
else
  echo "→ inserting the RUM snippet before </head>"
  # A `#` inside this object literal is not a JavaScript comment — it's a
  # SyntaxError, and SplunkRum.init never runs, with the snippet still fully
  # present in the served HTML (grepping for its presence proves nothing —
  # see labs/rum/petclinic_browser_test.py's report_rum_status for the three
  # distinct failure modes this can produce). Every value below is a plain
  # string, not a comment, on purpose.
  python3 - "$WORK/index.html" "$REALM" "$RUM_TOKEN" "$WS_USER" <<'PY'
import sys
path, realm, token, ws_user = sys.argv[1:5]
snippet = f'''  <!-- Splunk Real User Monitoring -->
  <script src="https://cdn.signalfx.com/o11y-gdi-rum/latest/splunk-otel-web.js"
          crossorigin="anonymous"></script>
  <script>
    SplunkRum.init({{
      realm: "{realm}",
      rumAccessToken: "{token}",
      applicationName: "{ws_user}-petclinic-rum",
      deploymentEnvironment: "{ws_user}-k8s-petclinic-env"
    }});
  </script>
</head>'''
with open(path) as f:
    html = f.read()
if '</head>' not in html:
    sys.exit("no </head> found in the served page — layout changed upstream, check by hand")
html = html.replace('</head>', snippet, 1)
with open(path, 'w') as f:
    f.write(html)
PY
fi

echo "→ creating/updating ConfigMap $CM_NAME in namespace $NAMESPACE"
kubectl create configmap "$CM_NAME" -n "$NAMESPACE" \
  --from-file=index.html="$WORK/index.html" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "→ mounting it over the served file on deployment/$DEPLOYMENT"
MOUNT_PATH=/application/BOOT-INF/classes/static/index.html

# Real bug caught live, not guessed: checking "is the array non-empty" is not
# the same as "does OUR entry already exist" — a naive re-run that only
# checked non-emptiness appended a SECOND "rum-index" volume/volumeMount on
# top of the first, and the apiserver rejected it ("Duplicate value... must be
# unique"). Check for our own named entry specifically, and treat its
# presence as "already mounted, nothing to do" rather than re-patching.
already_mounted=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="rum-index")].name}' 2>/dev/null)

if [ -n "$already_mounted" ]; then
  echo "  already mounted on this Deployment — skipping the patch"
else
  # volumes/volumeMounts don't exist as arrays on this Deployment yet
  # (verified live) — `add` on the array path creates it; if a later change
  # to the base manifest ever adds other volumes first, append instead so it
  # doesn't clobber them.
  if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
       -o jsonpath='{.spec.template.spec.volumes}' | grep -q '.'; then
    VOL_PATH="/spec/template/spec/volumes/-"
    VOL_VALUE='{"name":"rum-index","configMap":{"name":"'"$CM_NAME"'"}}'
  else
    VOL_PATH="/spec/template/spec/volumes"
    VOL_VALUE='[{"name":"rum-index","configMap":{"name":"'"$CM_NAME"'"}}]'
  fi

  if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
       -o jsonpath='{.spec.template.spec.containers[0].volumeMounts}' | grep -q '.'; then
    VM_PATH="/spec/template/spec/containers/0/volumeMounts/-"
    VM_VALUE='{"name":"rum-index","mountPath":"'"$MOUNT_PATH"'","subPath":"index.html"}'
  else
    VM_PATH="/spec/template/spec/containers/0/volumeMounts"
    VM_VALUE='[{"name":"rum-index","mountPath":"'"$MOUNT_PATH"'","subPath":"index.html"}]'
  fi

  kubectl patch deployment "$DEPLOYMENT" -n "$NAMESPACE" --type=json -p "[
    {\"op\": \"add\", \"path\": \"$VOL_PATH\", \"value\": $VOL_VALUE},
    {\"op\": \"add\", \"path\": \"$VM_PATH\", \"value\": $VM_VALUE}
  ]"
fi

echo "→ waiting for the rollout"
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s

echo "→ confirming the snippet is now served"
# `kubectl rollout status` reporting done and the NodePort actually routing to
# the new pod are not the same instant — a curl fired immediately after can
# still land on the old pod's connection or a not-quite-warm new one. Real
# gotcha, caught live: the very first check here failed once even though the
# ConfigMap/mount were already correct and a curl two seconds later succeeded.
# Retry briefly rather than treat that as a real failure.
served=0
for _ in 1 2 3 4 5; do
  if curl -fsSL --max-time 20 "$APP_URL/" 2>/dev/null | grep -q 'SplunkRum.init'; then
    served=1; break
  fi
  sleep 3
done
if [ "$served" = "1" ]; then
  echo "✓ RUM snippet is live at $APP_URL/"
else
  echo "✗ snippet not found in the served page after rollout — check kubectl describe pod" >&2
  exit 1
fi
