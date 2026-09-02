#!/usr/bin/env bash
# Packages the seven capstone dashboards into one installable Splunk app.
#
# The views are NOT duplicated in the app source tree — they are copied in from
# labs/dashboards/ at build time, so labs/dashboards/*.xml stays the single
# source of truth and the app can never drift from the file the guides link to.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source versions.env

SRC=labs/dashboards/app/k8s_ws_dashboards
OUT=labs/dashboards/dist
STAGE=.app-build-tmp

rm -rf "$STAGE" && mkdir -p "$STAGE" "$OUT"
cp -R "$SRC" "$STAGE/k8s_ws_dashboards"
V="$STAGE/k8s_ws_dashboards/default/data/ui/views"

# view name in Splunk  <-  source file in labs/dashboards
cp labs/dashboards/fw2-dashboard.xml                "$V/k8s_ws_fw2_dashboard.xml"
cp labs/dashboards/fw2-hubble-logs-dashboard.xml    "$V/k8s_ws_hubble_logs.xml"
cp labs/dashboards/aw1-dashboard.xml                "$V/k8s_ws_aw1_dashboard.xml"
cp labs/dashboards/aw1-infra-dashboard.xml          "$V/k8s_ws_infra_dashboard.xml"
cp labs/dashboards/aw1-cilium-metrics-dashboard.xml "$V/k8s_ws_cilium_metrics.xml"
cp labs/dashboards/aw2-dashboard.xml                "$V/k8s_ws_aw2_dashboard.xml"
cp labs/dashboards/apm-traces-dashboard.xml         "$V/k8s_ws_apm_traces.xml"

# Keep app.conf's version in step with versions.env rather than in two places.
sed -i.bak "s/^version = .*/version = ${WORKSHOP_APP_VERSION}/" \
  "$STAGE/k8s_ws_dashboards/default/app.conf" && rm -f "$STAGE/k8s_ws_dashboards/default/app.conf.bak"

for f in "$V"/*.xml; do
  python3 -c "import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$f" \
    || { echo "MALFORMED: $f" >&2; exit 1; }
done

TGZ="$OUT/k8s-ws-dashboards-${WORKSHOP_APP_VERSION}.tgz"
rm -f "$TGZ"
tar -C "$STAGE" -czf "$TGZ" k8s_ws_dashboards
rm -rf "$STAGE"

echo
echo "  $TGZ  ($(du -h "$TGZ" | cut -f1))"
tar tzf "$TGZ" | grep 'ui/views' | sed 's|^|    |'
echo
echo "  Install:  splunk install app <file> -auth admin:<pw>     # no restart needed"
