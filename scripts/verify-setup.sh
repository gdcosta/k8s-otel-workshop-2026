#!/usr/bin/env bash
# Asserts the host is ready for Foundational Workshop #1.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
pass=0; fail=0; skipped=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){   printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }
skip(){ printf '  \033[33m•\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; skipped=$((skipped+1)); }

# Version strings, the way each tool actually reports them in 2026.
# `kubectl version --short` was REMOVED — the flag now errors, and
# `kubectl version --short 2>/dev/null | head -1` exits 0 with empty output, so
# an `||` fallback after it never fires. Use the JSON form (what 00-setup does).
version_of(){
  local v=""
  case "$1" in
    kubectl)
      if command -v jq >/dev/null 2>&1; then
        v=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // empty' 2>/dev/null)
      fi
      # No jq, or jq gave nothing: parse the human-readable client output.
      if [ -z "$v" ]; then
        v=$(kubectl version --client 2>/dev/null | sed -n 's/^Client Version:[[:space:]]*//p' | head -1)
      fi
      if [ -z "$v" ]; then
        v=$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
      fi
      ;;
    *)
      v=$("$1" version --short 2>/dev/null | head -1)
      [ -n "$v" ] || v=$("$1" version 2>/dev/null | head -1)
      ;;
  esac
  printf '%s' "${v:-version unknown}"
}

echo "Verifying workshop host"; echo

[ "$(. /etc/os-release; echo $VERSION_ID)" = "24.04" ] && ok "Ubuntu 24.04" \
  || no "not Ubuntu 24.04" "other releases are untested"
[ "$(dpkg --print-architecture)" = "amd64" ] && ok "amd64" \
  || no "not amd64" "Splunk Enterprise has no Linux ARM64 build"

driver=$(docker info -f '{{.Driver}}' 2>/dev/null || sudo -n docker info -f '{{.Driver}}' 2>/dev/null)
if [ -n "$driver" ]; then
  ok "docker running (driver: $driver)"
else
  no "docker not usable" "sudo systemctl status docker; check the overlay module"
fi

# The single most common hardened-image blocker.
#
# The mount test below needs root, and the `splunk` user deliberately has NO
# sudo (00-setup step 5) — this script is normally run as splunk. A sudo
# permission error is not evidence that overlay is blocked, so it must never be
# reported as "overlay BLOCKED": that message sends participants off to the
# hardened-image troubleshooting for a problem they do not have.
#
# Docker's own storage driver is the better signal anyway. If dockerd is running
# on `overlay2`/`overlayfs`, the kernel demonstrably supports overlay.
if printf '%s' "$driver" | grep -qi 'overlay'; then
  ok "overlay filesystem usable (docker storage driver: $driver)"
elif sudo -n true 2>/dev/null; then
  if sudo -n mkdir -p /tmp/ov/{l,u,w,m} 2>/dev/null && \
     sudo -n mount -t overlay overlay -o lowerdir=/tmp/ov/l,upperdir=/tmp/ov/u,workdir=/tmp/ov/w /tmp/ov/m 2>/dev/null; then
    ok "overlay filesystem usable (mount test)"
    sudo -n umount /tmp/ov/m 2>/dev/null
  else
    no "overlay BLOCKED" "no container runtime can work — see troubleshooting: hardened images"
  fi
  sudo -n rm -rf /tmp/ov 2>/dev/null
else
  skip "overlay not checked (needs sudo)" \
       "the splunk user has no sudo by design; docker reports storage driver '${driver:-unknown}'. To test the mount explicitly, run this script as ubuntu."
fi

for t in minikube kubectl helm; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t present ($(version_of "$t"))"
  else
    no "$t missing" "re-run bootstrap.sh"
  fi
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
if [ "$fail" -eq 0 ]; then
  printf '\033[32mHost ready — %d/%d checks passed.\033[0m' "$pass" "$((pass+fail))"
  [ "$skipped" -gt 0 ] && printf ' (%d not checked)' "$skipped"
  echo
else
  printf '\033[31m%d of %d checks failed.\033[0m\n' "$fail" "$((pass+fail))"
  exit 1
fi
