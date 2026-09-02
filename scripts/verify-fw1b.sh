#!/usr/bin/env bash
# Asserts the end state of Foundational Workshop #1b (Cilium networking).
# Exit 0 = module complete. Used by participants and when validating a chart bump.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?set WS_USER first: export WS_USER=<your-username>}"

pass=0; fail=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){   printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }

echo "Verifying Foundational Workshop #1b (WS_USER=$WS_USER)"
echo

NS=petclinic

cilium status --wait >/dev/null 2>&1 \
  && ok "Cilium reports healthy (cilium status --wait)" \
  || no "Cilium is not healthy" "run: cilium status --wait   (look for a non-OK line)"

# Six services, six CiliumNetworkPolicy objects — each must exist and be VALID.
for p in discovery-server config-server customers-service vets-service visits-service api-gateway; do
  valid=$(kubectl get cnp "$p" -n "$NS" -o jsonpath='{.status.derived-generation}' 2>/dev/null)
  # derived-generation is only ever set on a policy Cilium has actually processed;
  # the human-readable column is the more reliable signal, so check that instead.
  col=$(kubectl get cnp "$p" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Valid")].status}' 2>/dev/null)
  if [ -n "$col" ]; then
    [ "$col" = "True" ] \
      && ok "CiliumNetworkPolicy/$p is VALID" \
      || no "CiliumNetworkPolicy/$p is not VALID" "kubectl get cnp $p -n $NS -o yaml"
  else
    # Older cilium-cli output shape: fall back to the plain table column.
    kubectl get cnp "$p" -n "$NS" 2>/dev/null | tail -1 | grep -q 'True' \
      && ok "CiliumNetworkPolicy/$p is VALID" \
      || no "CiliumNetworkPolicy/$p is not VALID or missing" "kubectl get cnp $p -n $NS"
  fi
done

desired=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
current=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.status.currentNumberScheduled}' 2>/dev/null)
[ "${desired:-1}" = "0" ] && [ "${current:-1}" = "0" ] \
  && ok "kube-proxy DaemonSet is at 0 desired / 0 current" \
  || no "kube-proxy still has scheduled pods (desired=${desired:-?}, current=${current:-?})" \
        "kubectl patch daemonset kube-proxy -n kube-system -p '{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"non-existing\":\"true\"}}}}}'"

class=$(kubectl get ingress petclinic -n "$NS" -o jsonpath='{.spec.ingressClassName}' 2>/dev/null)
[ "$class" = "cilium" ] \
  && ok "ingress/petclinic exists with ingressClassName: cilium" \
  || no "ingress/petclinic missing or not on the cilium class" "kubectl apply -f petclinic-ingress.yaml"

nodeport=$(kubectl get svc cilium-ingress-petclinic -n "$NS" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null)
case "$nodeport" in
  ''|0)
    no "cilium-ingress-petclinic has no real NodePort" "check loadbalancerMode=dedicated is set: helm get values cilium -n kube-system"
    ;;
  *)
    ok "cilium-ingress-petclinic has a real NodePort ($nodeport)"
    ;;
esac

if [ -n "${nodeport:-}" ] && [ "$nodeport" != "0" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://192.168.49.2:${nodeport}/" 2>/dev/null)
  [ "$code" = "200" ] \
    && ok "the SPA answers HTTP 200 through the Ingress NodePort ($nodeport)" \
    || no "Ingress NodePort returned HTTP ${code:-000}" \
          "check api-gateway's CiliumNetworkPolicy allows fromEntities: [host, world, ingress] — see FW1b §5"
else
  no "skipped the Ingress curl check — no NodePort to test" "fix the NodePort check above first"
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mFW1b complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else
  printf '\033[31m%d of %d checks failed.\033[0m See the Troubleshooting section in docs/01b-foundational-1b.\n' "$fail" "$((pass+fail))"
  exit 1
fi
