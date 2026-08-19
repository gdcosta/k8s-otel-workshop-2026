#!/usr/bin/env bash
# Asserts the end state of Foundational Workshop #1.
# Exit 0 = module complete. Used by participants and by the CI canary.
# NOTE: no `pipefail` here. `cmd | grep -q` makes cmd exit 141 (SIGPIPE)
# when grep matches early, which pipefail would report as a failed check.
set -u
: "${WS_USER:?set WS_USER first: export WS_USER=<your-username>}"

pass=0; fail=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){   printf '  \033[31m✗\033[0m %s\n' "$1"; printf '      → %s\n' "$2"; fail=$((fail+1)); }

echo "Verifying Foundational Workshop #1 (WS_USER=$WS_USER)"
echo

kubectl get nodes 2>/dev/null | grep -q ' Ready ' \
  && ok "minikube node is Ready" \
  || no "minikube node not Ready" "run: minikube status"

n=$(kubectl logs kube-apiserver-minikube -n kube-system 2>/dev/null | grep -c 'audit.k8s.io/v1')
[ "${n:-0}" -gt 0 ] \
  && ok "API server is emitting audit events ($n seen)" \
  || no "no audit events" "restart minikube with --extra-config=apiserver.audit-policy-file=..."

getent hosts minikube >/dev/null \
  && ok "'minikube' resolves" \
  || no "'minikube' does not resolve" "as ubuntu: echo -e \"\$(minikube ip)\tminikube\" | sudo tee -a /etc/hosts"

docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${WS_USER}/petclinic-otel:v1$" \
  && ok "image ${WS_USER}/petclinic-otel:v1 present in minikube store" \
  || no "image missing" "run: eval \$(minikube -p minikube docker-env) && rebuild"

avail=$(kubectl get deploy "${WS_USER}-petclinic-otel-deployment" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
[ "${avail:-0}" -ge 1 ] \
  && ok "deployment has $avail available replica(s)" \
  || no "deployment not available" "kubectl describe deploy ${WS_USER}-petclinic-otel-deployment"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://minikube:30000/ 2>/dev/null)
[ "$code" = "200" ] \
  && ok "PetClinic answers HTTP 200 on NodePort 30000" \
  || no "PetClinic returned HTTP ${code:-000}" "kubectl logs deploy/${WS_USER}-petclinic-otel-deployment"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mFW1 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else
  printf '\033[31m%d of %d checks failed.\033[0m See the Troubleshooting section in docs/01-foundational-1.\n' "$fail" "$((pass+fail))"
  exit 1
fi
