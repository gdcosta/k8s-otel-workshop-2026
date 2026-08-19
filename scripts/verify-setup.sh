#!/usr/bin/env bash
# Asserts the host is ready for Foundational Workshop #1.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }

echo "Verifying workshop host"; echo

[ "$(. /etc/os-release; echo $VERSION_ID)" = "24.04" ] && ok "Ubuntu 24.04" \
  || no "not Ubuntu 24.04" "other releases are untested"
[ "$(dpkg --print-architecture)" = "amd64" ] && ok "amd64" \
  || no "not amd64" "Splunk Enterprise has no Linux ARM64 build"

if sudo -n docker info >/dev/null 2>&1 || docker info >/dev/null 2>&1; then
  ok "docker running (driver: $(docker info -f '{{.Driver}}' 2>/dev/null || sudo docker info -f '{{.Driver}}'))"
else no "docker not usable" "sudo systemctl status docker; check the overlay module"; fi

# the single most common hardened-image blocker
if sudo mkdir -p /tmp/ov/{l,u,w,m} 2>/dev/null && \
   sudo mount -t overlay overlay -o lowerdir=/tmp/ov/l,upperdir=/tmp/ov/u,workdir=/tmp/ov/w /tmp/ov/m 2>/dev/null; then
  ok "overlay filesystem usable"; sudo umount /tmp/ov/m
else no "overlay BLOCKED" "no container runtime can work — see troubleshooting: hardened images"; fi
sudo rm -rf /tmp/ov 2>/dev/null

for t in minikube kubectl helm; do
  command -v $t >/dev/null && ok "$t present ($($t version --short 2>/dev/null | head -1 || $t version 2>/dev/null | head -1))" \
    || no "$t missing" "re-run bootstrap.sh"
done

id splunk >/dev/null 2>&1 && ok "splunk user exists" || no "no splunk user" "re-run bootstrap.sh"
id -nG splunk 2>/dev/null | grep -qw docker && ok "splunk in docker group" \
  || no "splunk not in docker group" "sudo usermod -aG docker splunk"

getent hosts minikube >/dev/null && ok "'minikube' resolves" \
  || no "'minikube' does not resolve" "as ubuntu: echo -e '192.168.49.2\\tminikube' | sudo tee -a /etc/hosts"

[ -x /opt/splunk/bin/splunk ] && ok "Splunk Enterprise installed ($(/opt/splunk/bin/splunk version 2>/dev/null | awk '{print $2}'))" \
  || no "Splunk not installed" "re-run bootstrap.sh"

avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "${avail:-0}" -ge 40 ] && ok "disk: ${avail}G free" || no "only ${avail}G free" "need ~40G headroom"

echo
if [ "$fail" -eq 0 ]; then printf '\033[32mHost ready — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"; exit 1; fi
