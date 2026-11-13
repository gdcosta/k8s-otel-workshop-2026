#!/usr/bin/env bash
# Asserts the end state of Foundational Workshop #1.
# Exit 0 = module complete. Used by participants and when validating a chart bump.
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

docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${WS_USER}/petclinic-customers:v1$" \
  && ok "image ${WS_USER}/petclinic-customers:v1 present in minikube store" \
  || no "customers-service image missing" "run: eval \$(minikube -p minikube docker-env) && rebuild"

# PetClinic lives in its own namespace, not default — see FW1 §6.
NS=petclinic

kubectl get namespace "$NS" >/dev/null 2>&1 \
  && ok "namespace/$NS exists" \
  || no "namespace/$NS not found" "kubectl apply -f <the manifest> — it creates the namespace as part of the same file"

# The six services, each as its own Deployment. config-server first since
# everything else's init container depends on it, and a config-server that
# never got Ready explains every other row failing at once.
for d in config-server discovery-server customers-service visits-service vets-service api-gateway; do
  avail=$(kubectl get deploy "$d" -n "$NS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
  [ "${avail:-0}" -ge 1 ] \
    && ok "deployment/$d has $avail available replica(s)" \
    || no "deployment/$d not available" "kubectl describe deploy/$d -n $NS ; kubectl logs deploy/$d -n $NS"
done

# grep -c counts matching LINES, not matches — the Eureka response is one line
# with all four names on it, so -c alone would always report 1. Pipe through
# wc -l instead to count actual occurrences.
n=$(kubectl exec -n "$NS" deploy/discovery-server -- curl -s --max-time 10 -H 'Accept: application/json' http://localhost:8761/eureka/apps 2>/dev/null \
    | grep -o '"name":"[A-Z-]*"' | sort -u | wc -l)
[ "${n:-0}" -ge 4 ] \
  && ok "$n services registered in Eureka" \
  || no "fewer than 4 services registered in Eureka" "kubectl logs deploy/discovery-server -n $NS ; check each service's own log for Eureka registration errors"

# config-server must never be talking to GitHub — that's the whole point of
# the native profile. A log line here means it silently fell back to git.
kubectl logs deploy/config-server -n "$NS" 2>/dev/null | grep -qiE 'clon|fetch.*github' \
  && no "config-server is reaching out to GitHub" "check SPRING_PROFILES_ACTIVE=native and GIT_REPO=/config are set on the config-server container" \
  || ok "config-server is serving from the local ConfigMap, not GitHub"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://minikube:30000/ 2>/dev/null)
[ "$code" = "200" ] \
  && ok "the SPA answers HTTP 200 on NodePort 30000" \
  || no "gateway returned HTTP ${code:-000}" "kubectl logs deploy/api-gateway -n $NS ; a 503 that clears on retry is Eureka registry-cache lag, not a failure — see FW1 §6"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://minikube:30000/api/vet/vets 2>/dev/null)
[ "$code" = "200" ] \
  && ok "a request through the gateway reaches vets-service" \
  || no "gateway route /api/vet/vets returned HTTP ${code:-000}" "retry once — see the Eureka registry-cache note above; if it persists, kubectl logs deploy/api-gateway -n $NS"

echo
if [ "$fail" -eq 0 ]; then
  printf '\033[32mFW1 complete — %d/%d checks passed.\033[0m\n' "$pass" "$((pass+fail))"
else
  printf '\033[31m%d of %d checks failed.\033[0m See the Troubleshooting section in docs/01-foundational-1.\n' "$fail" "$((pass+fail))"
  exit 1
fi
