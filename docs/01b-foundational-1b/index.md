# Foundational Workshop #1b — Kubernetes Networking with Cilium

**Duration:** ~2.5 hours · **Prerequisite:** [FW #1](../01-foundational-1/index.md) complete
(`./scripts/verify-fw1.sh` passes)

This module is not a detour into a niche CNI feature — it's here because the primary
audience for this workshop is architects who need Kubernetes specifically to deploy the
**Splunk Operator**, and Cilium is a required component of that real deployment. Everything
below is taught content, not optional bonus material.

By the time you got here, [FW #1 §2](../01-foundational-1/index.md#2-start-kubernetes)
already installed Cilium as the cluster's CNI — that's the one small footprint this module
left in FW #1, because the CNI is chosen at cluster creation and can't be swapped without
recreating the cluster. Everything else — observing real traffic, writing
`CiliumNetworkPolicy` rules, breaking and fixing a real flow on purpose, replacing
kube-proxy, and standing up Ingress — happens here.

By the end you will have:

- [x] Watched the six services' real traffic with Hubble and built a required-traffic graph
      from evidence, not assumption
- [x] A default-deny + explicit-allow `CiliumNetworkPolicy` covering all six services, both
      ingress and egress
- [x] Broken one call path on purpose with a deny policy, watched it fail in Hubble and
      `curl`, then restored it
- [x] Full kube-proxy replacement running cleanly under Cilium's own eBPF dataplane
- [x] PetClinic reachable through Cilium's own Envoy-based Ingress controller, tunnel-based
      from your laptop — no new public port, ever

## Session variables

```bash
source ~/.workshop-env
echo "$WS_USER on $LOCAL_IP ($PUB_DNS)"
```

??? info "Missing, or starting from a fresh shell?"
    The file is created during [host setup](../00-setup/index.md). If it isn't there:

    ```bash
    cat > ~/.workshop-env <<'EOF'
    export WS_USER=wsuser01          # ← your own, lowercase, no spaces
    export LOCAL_IP=$(ec2metadata --local-ipv4)
    export PUB_DNS=$(ec2metadata --public-hostname)
    export CHART_VERSION=0.158.0
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
    EOF
    chmod 600 ~/.workshop-env
    source ~/.workshop-env
    echo '[ -f ~/.workshop-env ] && . ~/.workshop-env' >> ~/.profile
    ```

    Values added by later modules:

    | Variable | Set in | Used for |
    |---|---|---|
    | `HEC_TOKEN` | FW #2 step 3 | Collector → Splunk Enterprise |
    | `O11Y_REALM` | AW #2 step 1 | Observability Cloud realm, e.g. `us1` |

    Tokens themselves stay in files (`~/.o11y-token`, `~/.rum-token`) rather than in here,
    so they're never echoed to a terminal.

---

## 1. Watch the traffic before you write any policy

!!! abstract "Learning moment — Hubble is Cilium's own flow visibility, no extra install"
    Cilium ships with Hubble's local flow buffer enabled by default — every packet Cilium's
    eBPF dataplane forwards or drops is recorded and queryable through the `cilium` agent's
    own Unix socket, no separate Hubble Relay or UI needed for a single-node cluster. Reach
    it with `kubectl exec` into the Cilium DaemonSet:

    ```bash
    kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic -n 20
    ```

Run that now, with the app idling. A single, real capture from this exact command looked
like this:

```
Sep  2 00:52:42.037: 10.0.0.208:39274 (host) -> petclinic/vets-service-7558dc6845-jgdqt:8083 (ID:62956) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Sep  2 00:52:42.037: 10.0.0.208:34648 (host) -> petclinic/api-gateway-689dcc744-hh2nt:8080 (ID:1586) policy-verdict:L3-L4 INGRESS ALLOWED (TCP Flags: SYN)
Sep  2 00:52:42.037: 10.0.0.208:59766 (host) <- petclinic/visits-service-c8b894855-85wgw:8082 (ID:64908) to-stack FORWARDED (TCP Flags: ACK, PSH)
Sep  2 00:52:43.187: petclinic/api-gateway-689dcc744-hh2nt:40752 (ID:1586) -> petclinic/discovery-server-694859b9bc-j67mw:8761 (ID:35445) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
```

Two different kinds of source are visible in that one screenful, and the difference matters
for everything that follows:

- `10.0.0.208 (host) -> petclinic/vets-service:8083` — that's the node's kubelet doing its
  liveness/readiness probe, straight into the pod's own application port. There's no
  separate probe port; the probe and real traffic share 8083.
- `petclinic/api-gateway:40752 -> petclinic/discovery-server:8761` — that's a **real pod**
  talking to a **real pod**: `api-gateway`'s Eureka heartbeat into `discovery-server`, with
  both ends carrying their actual workload identity, not a proxy or a NAT artifact.

Filter to just the interesting traffic type (`--protocol dns`, `--verdict DROPPED`,
`--to-pod`, `--from-pod` all work the same way) and leave it running in a second terminal
while you click around the app from [FW #1 §7](../01-foundational-1/index.md#7-reach-the-application) —
watching real flows appear as you interact with the SPA is worth five minutes before writing
a single policy line.

### The required-traffic graph

Building this from evidence rather than guessing is the actual exercise. Watching Hubble
across a normal restart-and-settle cycle turns up exactly six kinds of flow:

| Traffic | Path | Port | Source identity Cilium records |
|---|---|---|---|
| DNS | every pod → `coredns` | 53/UDP+TCP | the pod's own identity |
| kubelet probes | node → each pod's own app port | app port (no separate probe port) | `reserved:host` |
| config fetch (once, at startup) | **all six** services, including `discovery-server` itself, → `config-server` | 8888/TCP | real pod identity in steady state |
| Eureka registration + heartbeat | `customers-service`, `vets-service`, `visits-service`, `api-gateway` → `discovery-server` | 8761/TCP | real pod identity in steady state |
| Eureka-resolved gateway calls | `api-gateway` → `customers-service` / `vets-service` / `visits-service`, straight to the pod IP, not the ClusterIP | 8081 / 8083 / 8082 | real `api-gateway` pod identity |
| External access | tunnel/`curl` → `api-gateway` NodePort | 8080/TCP | `reserved:host`, `reserved:world`, and later `reserved:ingress` — see below |

Two things on that table are easy to miss without watching Hubble first: `config-server`
gets called by **`discovery-server` too**, not just the three business services and the
gateway — it's a Spring Cloud Config Client exactly like everything else. And `api-gateway`'s
calls to its three backends bypass the ClusterIP path entirely — Spring Cloud LoadBalancer
resolves the Eureka-registered pod address itself and connects directly, which is *why*
those flows show up with the gateway's real identity rather than something collapsed by a
Service.

!!! danger "The gotcha that changed the policy design: Service-mediated traffic's identity is not uniform"
    Everything routed through a Kubernetes Service — the config-fetch and Eureka calls in the
    table above — is DNAT'd by kube-proxy before Cilium's policy engine ever evaluates it.
    In **steady state**, that resolves cleanly to the calling pod's real identity, which is
    what the table shows and what a `fromEndpoints`/`toEndpoints` match expects.

    But during a **synchronized restart of all six Deployments at once**, the exact same
    kind of flow — the same service, the same port — was instead observed with source
    identity collapsed to `reserved:host` (labels `[reserved:host, reserved:kube-apiserver]`),
    not the calling pod. Cilium's identity cache and kube-proxy's iptables rules are both
    churning while every pod IP in the namespace is being recreated at once, and the flow
    gets attributed to the node rather than the pod that actually sent it.

    Both identities are real and both need allowing, or one of them produces a genuine,
    live `DROPPED` flow depending on whether you happen to test during a cold start or after
    things settle — not a theoretical edge case, an actual gap this workshop's own policy
    set hit and fixed. That's why every policy below that receives Service-mediated traffic
    carries **two** `ingress`/`egress` entries for the same logical caller: one
    `fromEndpoints`/`toEndpoints` match on the real pod label, one `fromEntities: [host]`
    fallback for the collapsed case.

    `api-gateway`'s own NodePort ingress has an even less predictable version of the same
    problem: back-to-back requests to the *same* NodePort, from the *same* real source, were
    seen as `reserved:host` on one connection and `reserved:world` on the next, in one
    isolated capture. Allowing only `host` intermittently dropped the exact traffic this
    workshop's documented access path relies on — both entities are required in that policy,
    not a stylistic choice.

---

## 2. Build the default-deny + explicit-allow policy set

!!! abstract "Learning moment — there's no separate 'default-deny' policy to write"
    Cilium's `CiliumNetworkPolicy` model is per-endpoint and per-direction: the moment
    **any** policy's `endpointSelector` matches a pod, that pod's traffic in whichever
    direction(s) the policy specifies (`ingress`, `egress`, or both) switches from
    ambient allow-all to **deny-by-default, explicit-allow-only** — for that pod alone.
    There's no cluster-wide switch to flip first. Each of the six policies below carries
    both `ingress` and `egress` rules, so applying it to a service is what locks that service
    down, in both directions, in the same step.

Create the six files below (or copy them from
[Reference — complete files](#reference-complete-files) at the end of this module), and
apply them **one service at a time**, checking after each — that's genuinely how this was
tested, not applied blind in one shot, and it's the only way a bad rule tells you which
service caused it. `config-server` and `discovery-server` first, since every other service
depends on them.

### 2.1 `discovery-server`

This is the file that carries the `reserved:host` finding from the previous section, written
into the policy itself as a comment so the reasoning travels with the YAML:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: discovery-server
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: discovery-server
  # Two ingress sources are both real, confirmed live, not assumed:
  #  - In steady state, each client's registration/heartbeat call to
  #    discovery-server:8761 shows up in `hubble observe -o json` with the
  #    client's own real pod identity (customers-service, vets-service,
  #    visits-service, api-gateway) even though the connection is made via
  #    the ClusterIP and DNAT'd by kube-proxy (not Cilium) — so a precise
  #    fromEndpoints allowlist is both possible and correct here.
  #  - During a synchronized restart of all six deployments, the exact same
  #    kind of flow was instead observed with source identity collapsed to
  #    reserved:host (labels [reserved:host, reserved:kube-apiserver]) —
  #    apparently a transient effect of kube-proxy's iptables rules and
  #    Cilium's identity cache both churning while every pod IP in the
  #    namespace is being recreated at once. `host` is also kubelet's own
  #    real identity for its liveness/readiness probe into :8761.
  # Both are included so neither steady-state heartbeats nor a mass restart
  # get incorrectly dropped.
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: customers-service
        - matchLabels:
            app.kubernetes.io/name: vets-service
        - matchLabels:
            app.kubernetes.io/name: visits-service
        - matchLabels:
            app.kubernetes.io/name: api-gateway
      toPorts:
        - ports:
            - port: "8761"
              protocol: TCP
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8761"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    # discovery-server fetches its own config at startup, same as every other
    # service — see the traffic table above. Easy to miss: this pod isn't
    # restarted often once the lockdown is applied, so a policy missing this
    # rule can sit unnoticed for a long time before a restart ever exercises
    # the gap. Confirmed live.
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: config-server
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
```

Apply it and check:

```bash
kubectl apply -f discovery-server-netpol.yaml
kubectl get cnp discovery-server -n petclinic
```

### ✅ Checkpoint — `discovery-server` locked down cleanly

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --to-pod discovery-server --verdict DROPPED -n 20
```

<details>
<summary>Expected output</summary>

```
NAME                AGE   VALID
discovery-server    5s    True
```

No output from the `hubble observe --verdict DROPPED` command — an empty result here is the
pass condition, not a sign the command did nothing.
</details>

### 2.2 `config-server`

Same two-source reasoning as `discovery-server` — steady-state fetches show the real client
pod identity, a synchronized restart collapses to `reserved:host`, and kubelet's own probe is
also real `reserved:host`. This is the file that proves the "all six services including
`discovery-server` itself" finding from the traffic table above — `discovery-server` is in
the allowed caller list on equal footing with the three business services and the gateway:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: config-server
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: config-server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: customers-service
        - matchLabels:
            app.kubernetes.io/name: vets-service
        - matchLabels:
            app.kubernetes.io/name: visits-service
        - matchLabels:
            app.kubernetes.io/name: api-gateway
        - matchLabels:
            app.kubernetes.io/name: discovery-server
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
```

### ✅ Checkpoint — `config-server` locked down cleanly

```bash
kubectl apply -f config-server-netpol.yaml
kubectl get cnp config-server -n petclinic
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --to-pod config-server --verdict DROPPED -n 20
```

Same pass condition as before: `VALID True`, empty drop output.

### 2.3 `customers-service`

The first policy where `fromEndpoints` alone is sufficient on the busiest ingress rule — the
gateway's call bypasses the ClusterIP path entirely, so its identity is never collapsed:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: customers-service
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: customers-service
  ingress:
    # api-gateway calls customers-service by the Eureka-registered pod IP
    # directly (Spring Cloud LoadBalancer resolves the instance address
    # itself), bypassing the ClusterIP/kube-proxy path entirely — confirmed
    # live: this flow's source identity in `hubble observe -o json` is the
    # real api-gateway pod identity, not reserved:host. So this is the one
    # ingress rule in the whole set that can use a true fromEndpoints match.
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: api-gateway
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    # kubelet's own readiness/liveness probe, direct to the pod IP on the
    # same port — confirmed live via hubble as source reserved:host.
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    # Confirmed live (see discovery-server/config-server's header comments):
    # egress toEndpoints correctly matches these Service-mediated calls even
    # though kube-proxy, not Cilium, performs the DNAT — the identity
    # collapse to reserved:host only happens on the *receiving* side after
    # NAT, not at egress evaluation on the sender.
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: discovery-server
      toPorts:
        - ports:
            - port: "8761"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: config-server
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
```

### ✅ Checkpoint — `customers-service` locked down cleanly

```bash
kubectl apply -f customers-service-netpol.yaml
kubectl get cnp customers-service -n petclinic
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --to-pod customers-service --verdict DROPPED -n 20
```

### 2.4 `vets-service` and `visits-service`

Both are shaped identically to `customers-service` — same two ingress sources (`api-gateway`
by `fromEndpoints`, kubelet by `fromEntities: [host]`), same DNS + `discovery-server` +
`config-server` egress — with only the port and the endpoint's own name changed:
`vets-service` on `8083`, `visits-service` on `8082`. Full text for both is in
[Reference — complete files](#reference-complete-files); apply and check each the same way:

```bash
kubectl apply -f vets-service-netpol.yaml
kubectl get cnp vets-service -n petclinic
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --to-pod vets-service --verdict DROPPED -n 20

kubectl apply -f visits-service-netpol.yaml
kubectl get cnp visits-service -n petclinic
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --to-pod visits-service --verdict DROPPED -n 20
```

### 2.5 `api-gateway`

The one policy that's deliberately more open on ingress — `api-gateway` is the workshop's
one intended public entry point (see FW #1 §6's "one ingress point, everything else
internal"), so allowing `world` here, and only here, matches the app's own design rather
than weakening the lockdown:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-gateway
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: api-gateway
  ingress:
    # NodePort traffic (the SSH-tunnel / curl access pattern FW1 documents)
    # arrives via kube-proxy's NodePort iptables path, same as the
    # ClusterIP cases above — but confirmed live with a fresh isolated
    # capture that its resolved identity is NOT stable: back-to-back
    # requests to the same NodePort, from the same real source, were seen
    # as reserved:host on one connection and reserved:world on the next
    # (`hubble observe -o json` on the same test curl). Allowing only
    # `host` intermittently dropped the exact traffic this workshop's own
    # documented access path relies on, so both entities are required here.
    # This is also the intended boundary architecturally — api-gateway is
    # the one deliberately public entry point (see FW1 §6's "one ingress
    # point, everything else internal"), so allowing `world` here and only
    # here matches the app's own design, not a lockdown weakening.
    #
    # `ingress` added later (kube-proxy-replacement + Cilium Ingress
    # controller, sections 4-5 below): Cilium's own Envoy proxy — the thing
    # actually terminating the Ingress NodePort and forwarding to
    # api-gateway — connects with source identity reserved:ingress, not
    # host or world. Confirmed live: without this entry, `hubble observe
    # --verdict DROPPED` showed a real, continuous "Policy denied DROPPED"
    # against every SYN from "(ingress)" while curling the Ingress
    # NodePort, and Envoy's own response was 503 "upstream connect error
    # ... connection timeout" — Envoy was up and forwarding, our own
    # policy was the thing blocking it.
    - fromEntities:
        - host
        - world
        - ingress
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: discovery-server
      toPorts:
        - ports:
            - port: "8761"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: config-server
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
    # Direct pod-IP calls (Eureka-resolved), confirmed live as real pod
    # identity, not host-collapsed like the ClusterIP-only services above.
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: customers-service
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: vets-service
      toPorts:
        - ports:
            - port: "8083"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: visits-service
      toPorts:
        - ports:
            - port: "8082"
              protocol: TCP
```

!!! note "The `ingress` entity is not applied yet, but is already in this file"
    You'll see it flagged again in section 5, live, when Ingress itself is turned on — it's
    included here in advance so the file you apply now matches the final, reference version
    exactly. Applying it now costs nothing: `reserved:ingress` doesn't exist as a traffic
    source until the Ingress controller is running.

### ✅ Checkpoint — the full six-service lockdown

```bash
kubectl apply -f api-gateway-netpol.yaml
kubectl get cnp -n petclinic
```

<details>
<summary>Expected output</summary>

```
NAME                AGE   VALID
api-gateway         37m   True
config-server       40m   True
customers-service   39m   True
discovery-server    43m   True
vets-service        38m   True
visits-service      38m   True
```
</details>

With all six applied, generate a little real traffic and confirm nothing was over-locked:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://minikube:30000/
curl -s -o /dev/null -w '%{http_code}\n' http://minikube:30000/api/vet/vets
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --verdict DROPPED -n 50

~/k8s-otel-workshop/scripts/verify-fw1.sh
```

Zero drops, both `curl`s `200`, and `verify-fw1.sh` still 15/15 is the real, live-confirmed
end state of this section — the six-service app is functionally identical to before Cilium
locked it down, because the policy set was built from the traffic that was actually there.

---

## 3. Break something on purpose: the deliberate-failure demo

`visits-service` and `customers-service` have **no real dependency on each other** — nothing
in the six policies above allows a path between them, and nothing in the application ever
calls it. That makes it a safe pair to use as this module's own fault scenario: distinct from
[FW #2 §8's scale-to-zero fault](../02-foundational-2/index.md#8-cause-a-real-failure-and-find-it-in-splunk),
which is a *service-discovery* failure (Eureka has no healthy instance, so the caller fast-fails
before a connection is even attempted). This one is a *network-layer* failure instead — the
destination is running and correctly registered, the caller genuinely tries to connect, and
the packet is dropped at the CNI layer. That produces a **connection timeout**, not a clean
fast-fail — a much more true-to-production "everything looks healthy and it still doesn't
work" bug, and exactly what Hubble's flow visibility exists to diagnose.

First, temporarily open a path that the real lockdown never allows — this is demo scaffolding
only, not part of the required-traffic graph:

```yaml
# DEMO ONLY — not part of the real flow graph from section 2. visits-service
# and customers-service have no actual dependency on each other; this
# policy exists only to give the failure-demo something to break, by
# temporarily opening a path that the real lockdown never allows. Applied
# and removed within the same live session — never meant to persist.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: demo-allow-customers-ingress-from-visits
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: customers-service
  ingress:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: visits-service
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: demo-allow-visits-egress-to-customers
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: visits-service
  egress:
    - toEndpoints:
        - matchLabels:
            app.kubernetes.io/name: customers-service
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
```

```bash
kubectl apply -f demo-allow-visits-to-customers.yaml
```

Now apply the deny rule. `CiliumNetworkPolicy`'s `ingressDeny`/`egressDeny` take precedence
over any allow rule for the same endpoint — applying it on top of the allow just opened proves
deny-rule precedence live, rather than just relying on the absence of an allow rule (which
would be true anyway, and a much weaker demonstration):

```yaml
# Deliberate-failure demo: explicitly denies visits-service -> customers-
# service specifically, even though the temporary demo-allow policy above
# permits it. CiliumNetworkPolicy ingressDeny/egressDeny take precedence
# over any allow rule for the same endpoint, so this proves deny-rule
# precedence live rather than just relying on default-deny absence.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: demo-deny-visits-to-customers
  namespace: petclinic
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: customers-service
  ingressDeny:
    - fromEndpoints:
        - matchLabels:
            app.kubernetes.io/name: visits-service
      toPorts:
        - ports:
            - port: "8081"
              protocol: TCP
```

```bash
kubectl apply -f demo-deny-visits-to-customers.yaml
```

### ✅ Checkpoint — watch it fail, in two places at once

From `visits-service`, try to reach `customers-service` directly:

```bash
kubectl exec -n petclinic deploy/visits-service -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 http://customers-service:8081/owners
```

<details>
<summary>Expected output</summary>

A `curl` timeout — no HTTP code at all, just the command hanging until `--max-time` cuts it
off. Not a `403`, not a `refused` — a real connection timeout, because the SYN is silently
dropped at the CNI layer rather than rejected.
</details>

In a second terminal, watch Hubble catch it in real time:

```bash
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --from-pod visits-service --to-pod customers-service --verdict DROPPED -n 10
```

Expect a line reading `Policy denied by denylist DROPPED` against the exact flow the `curl`
above generated — the deny rule, not a missing allow, is what's stopping it.

Restore the real state — remove **both** demo policies, not just the deny rule, so nothing
outside the six-service lockdown from section 2 survives:

```bash
kubectl delete -f demo-deny-visits-to-customers.yaml
kubectl delete -f demo-allow-visits-to-customers.yaml

kubectl exec -n petclinic deploy/visits-service -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 http://customers-service:8081/owners

~/k8s-otel-workshop/scripts/verify-fw1.sh
```

Removing the deny rule alone restores the call path immediately — `verify-fw1.sh` is still
15/15 throughout this whole exercise, because none of it touches a real dependency.

---

## 4. Enable full kube-proxy replacement

!!! danger "Reversing an earlier call, deliberately — this is not a contradiction"
    Up to this point, kube-proxy has been left running untouched, on purpose — Cilium's
    scope was only `NetworkPolicy` and Hubble, and full kube-proxy replacement is a bigger
    blast radius than that scope needed for twenty simultaneous participants. That call was
    correct *for that scope*.

    It stops being correct here. Cilium's own Ingress controller needs to intercept
    Service/NodePort traffic through its own eBPF path — and kube-proxy staying in place
    directly prevents that. Confirmed precisely, not guessed: kube-proxy's own
    `iptables-save` rules reject Ingress traffic with `--reject-with icmp-port-unreachable`
    before Cilium's own rules get a chance to run. Three real options exist once Ingress
    becomes a requirement — hostNetwork-mode Ingress (keeps kube-proxy, untested here), full
    kube-proxy replacement (reopens the earlier risk, bigger blast radius), or a separate
    ingress-nginx install (no longer a Cilium-only story). This module takes full kube-proxy
    replacement, deliberately accepting that trade-off now that Ingress is a real
    requirement, not the unnecessary risk it was when NetworkPolicy and Hubble were the only
    things riding on this cluster.

Cilium needs a direct path to the Kubernetes API server once kube-proxy is gone — kube-proxy
was providing that path implicitly until now. Get the real address, don't assume it:

```bash
kubectl cluster-info
```

```
Kubernetes control plane is running at https://192.168.49.2:8443
```

Upgrade Cilium with that address and `kubeProxyReplacement=true`:

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
  --reuse-values \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.49.2 \
  --set k8sServicePort=8443
```

Stopping kube-proxy's own pods needs elevated permissions most environments won't grant for
a plain `kubectl delete daemonset kube-proxy` — the safe, standard equivalent is an
unsatisfiable `nodeSelector` patch. It stops kube-proxy's pod without deleting the object,
which keeps the DaemonSet itself intact and easy to reverse:

```bash
kubectl patch daemonset kube-proxy -n kube-system -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}'
```

### ✅ Checkpoint — kube-proxy is genuinely gone, nothing broke

```bash
kubectl get daemonset kube-proxy -n kube-system
cilium status --wait
kubectl get cnp -n petclinic
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --verdict DROPPED -n 50
~/k8s-otel-workshop/scripts/verify-fw1.sh
```

<details>
<summary>Expected output</summary>

```
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR
kube-proxy   0         0         0       0            0           kubernetes.io/os=linux,non-existing=true
```

`cilium status --wait` reports `OK`, all six `CiliumNetworkPolicy` objects still `VALID`,
zero dropped flows, `verify-fw1.sh` still 15/15. This isn't a coexistence test — Cilium's own
eBPF service table was already fully programmed and winning by rule ordering
(`--prepend-iptables-chains=true`) even *before* kube-proxy stopped, which is what removing
it entirely and re-testing confirms empirically.
</details>

!!! note "One harmless leftover: kube-proxy doesn't clean up after itself"
    kube-proxy's pod termination doesn't remove its own iptables rules. A live count on this
    exact cluster found **75 stale `KUBE-SVC`/`KUBE-SEP` entries** still present:

    ```bash
    minikube ssh -- sudo iptables-save -t nat | grep -c 'KUBE-SVC\|KUBE-SEP'
    ```

    They're dead, not dangerous — unreachable, because Cilium's prepended rules intercept
    every packet first. Worth knowing so a stray `KUBE-SVC` chain doesn't read as a sign
    something didn't clean up correctly; nothing in this module ever removes them, and
    nothing needs to.

---

## 5. Ingress via Cilium's own Envoy-based controller

Cilium ships its own Ingress controller, backed by the same Envoy proxy already running as
part of the Cilium DaemonSet — no separate `ingress-nginx` install, and no second component
to keep patched:

```bash
helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
  --reuse-values \
  --set ingressController.enabled=true \
  --set ingressController.loadbalancerMode=dedicated
```

!!! danger "`loadbalancerMode=dedicated`, not the chart's own `shared` default — a real BPF-wiring gap, not a config typo"
    Leave `loadbalancerMode` unset and the chart defaults to `shared`: every Ingress
    resource in the cluster reuses one common Service. On this Cilium-version /
    minikube-driver combination, `shared` mode **never wired the eBPF redirect from that
    Service to the local Envoy listener** — confirmed two layers deep, not assumed:

    - Envoy itself came up and served real traffic — `curl 127.0.0.1:19171` (its own
      listener) returned a real `503`, so Envoy was healthy and reachable.
    - But `cilium-dbg bpf lb list` — the raw eBPF load-balancer map, not the summary view —
      showed the Ingress Service's frontend entries with a literal `0.0.0.0:0` backend.
      Every *other* Service in the cluster, `api-gateway`'s own NodePort included, had a
      correctly populated entry in the same table.

    `dedicated` mode gives each Ingress resource its **own** Service instead of sharing one,
    and on this cluster the frontend entries came up correctly wired the moment it was set —
    confirmed live via the same `cilium-dbg bpf lb list` command:

    ```bash
    kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list | grep 30560
    ```

    ```
    0.0.0.0:30560/TCP (0)         0.0.0.0:0 (20) (0) [NodePort, non-routable, l7-load-balancer] (L7LB Proxy Port: 19171)
    192.168.49.2:30560/TCP (0)    0.0.0.0:0 (21) (0) [NodePort, l7-load-balancer] (L7LB Proxy Port: 19171)
    ```

    `[NodePort, l7-load-balancer] (L7LB Proxy Port: 19171)` is the exact wiring that was
    missing under `shared` mode. **Doc-worthy lesson beyond this one feature**: if a future
    Cilium feature introduces its own load-balancing mode, don't assume the chart's default
    is the tested path — verify the eBPF table, not just that Envoy itself is up.

Apply the `Ingress` resource. It has to reference the same `Service` your six-service
manifest already created in [FW #1 §6](../01-foundational-1/index.md#6-deploy-to-kubernetes):

```bash
cat > petclinic-ingress.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: petclinic
  namespace: petclinic
spec:
  ingressClassName: cilium
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${WS_USER}-petclinic-srv
                port:
                  number: 8080
EOF

kubectl apply -f petclinic-ingress.yaml
kubectl get ingress -n petclinic
```

`dedicated` mode creates a new Service just for this Ingress — `cilium-ingress-petclinic` —
with its own generated NodePorts:

```bash
kubectl get svc cilium-ingress-petclinic -n petclinic
```

```
NAME                       TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)                      AGE
cilium-ingress-petclinic   LoadBalancer   10.99.87.44   <pending>     80:30560/TCP,443:31575/TCP   8m
```

!!! warning "These NodePort numbers are generated, not pinned — read yours, don't assume ours"
    `30560`/`31575` are what this exact cluster generated; Helm assigns NodePorts from the
    default range on creation, and a different install (or a re-created Service) can land on
    different numbers. Confirm your own with the command above before using it anywhere
    else in this module, including the tunnel in the next section. `443` is listed but
    untested here — no TLS is configured on this `Ingress`.

### ✅ Checkpoint — Ingress answers, but check `api-gateway`'s policy first

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.49.2:$(kubectl get svc cilium-ingress-petclinic -n petclinic -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')/
```

If `api-gateway`'s policy from section 2.5 already includes `ingress` in its `fromEntities`
list, this returns `200` immediately. If you're working from an earlier version of that file
without it, you'll see the finding below live instead of just reading about it.

!!! danger "A new Cilium feature can introduce a traffic identity your existing policy has never seen"
    Turning on the Ingress controller creates a new source identity, `reserved:ingress` —
    Cilium's own Envoy proxy, forwarding Ingress traffic into the backend Service, connects
    with that identity rather than `host` or `world`. It didn't exist as a concept when the
    six `CiliumNetworkPolicy` objects were designed in section 2, because Ingress wasn't
    installed yet.

    Without `ingress` in `api-gateway`'s `fromEntities` list, the result is a genuine `503`,
    not a network-level failure — Envoy is up and successfully forwarding, and the request
    dies at `api-gateway`'s own policy instead:

    ```bash
    kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
      --to-pod api-gateway --verdict DROPPED -n 10
    ```

    ```
    Policy denied DROPPED  ... (ingress) -> petclinic/api-gateway:8080 ...
    ```

    The fix is one line — add `ingress` to `api-gateway`'s `fromEntities: [host, world]` (see
    the full file in section 2.5) — and re-apply:

    ```bash
    kubectl apply -f api-gateway-netpol.yaml
    curl -s -o /dev/null -w '%{http_code}\n' -D - http://192.168.49.2:30560/ | grep -i 'HTTP\|x-response-time\|^$' 2>/dev/null
    ```

    A real `200` with an actual upstream response header is the proof this is a genuine
    round-trip through Envoy into `api-gateway`, not a cached or short-circuited answer.

    **This isn't specific to Ingress.** Any future Cilium feature that introduces its own
    `reserved:*` identity will need the same treatment: locking down `NetworkPolicy` first
    and turning on a new Cilium feature second means revisiting the existing policies once
    that feature is live, not before.

Final full re-verification, with kube-proxy stopped and Ingress live:

```bash
kubectl get cnp -n petclinic
kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
  --verdict DROPPED -n 50
curl -s -o /dev/null -w '%{http_code}\n' http://minikube:30000/
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.49.2:30560/
~/k8s-otel-workshop/scripts/verify-fw1.sh
```

All six `CiliumNetworkPolicy` objects `VALID`, zero drops under combined load across **both**
NodePort 30000 (the original, raw path) and the new Ingress NodePort — that's the real,
fully re-verified end state this module leaves the cluster in.

---

## 6. Reach the application — the tunnel target changes

[FW #1 §7](../01-foundational-1/index.md#7-reach-the-application) tunnelled straight to the
raw NodePort: `ssh -L 8080:192.168.49.2:30000 ...`. That NodePort still works — `curl` against
it is fine for quick testing throughout the rest of this workshop and beyond. What changes is
the path a **human browser** uses: from here on, that goes through the Ingress controller
instead, the same tunnel-only posture as Splunk Web everywhere else in this workshop — never a
newly opened public port.

From a terminal **on your laptop** — not on the instance — using the NodePort you read back in
the checkpoint above:

```bash
ssh -i <your-key.pem> -L 8080:192.168.49.2:30560 splunk@<your-instance>
```

Leave it connected and open **<http://localhost:8080>**. Same PetClinic welcome page as FW #1
§7 — this module changes nothing about the application itself, only the network path in front
of it.

??? tip "Keep the raw-NodePort tunnel around too, if you're still using it for quick curl checks"
    Nothing stops you running both tunnels at once, on two different local ports:

    ```bash
    ssh -i <your-key.pem> -L 8080:192.168.49.2:30560 -L 8081:192.168.49.2:30000 splunk@<your-instance>
    ```

    `localhost:8080` → Ingress (the browser path from now on), `localhost:8081` → the raw
    NodePort (unaffected, works exactly as it did in FW #1).

---

## Reference — complete files

If something isn't behaving, compare your files against these rather than re-reading the
steps above. They're the exact files this module was tested with.

??? example "discovery-server-netpol.yaml"
    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: discovery-server
      namespace: petclinic
    spec:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: discovery-server
      ingress:
        - fromEndpoints:
            - matchLabels:
                app.kubernetes.io/name: customers-service
            - matchLabels:
                app.kubernetes.io/name: vets-service
            - matchLabels:
                app.kubernetes.io/name: visits-service
            - matchLabels:
                app.kubernetes.io/name: api-gateway
          toPorts:
            - ports:
                - port: "8761"
                  protocol: TCP
        - fromEntities:
            - host
          toPorts:
            - ports:
                - port: "8761"
                  protocol: TCP
      egress:
        - toEndpoints:
            - matchLabels:
                k8s-app: kube-dns
                k8s:io.kubernetes.pod.namespace: kube-system
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: config-server
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
    ```

??? example "config-server-netpol.yaml"
    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: config-server
      namespace: petclinic
    spec:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: config-server
      ingress:
        - fromEndpoints:
            - matchLabels:
                app.kubernetes.io/name: customers-service
            - matchLabels:
                app.kubernetes.io/name: vets-service
            - matchLabels:
                app.kubernetes.io/name: visits-service
            - matchLabels:
                app.kubernetes.io/name: api-gateway
            - matchLabels:
                app.kubernetes.io/name: discovery-server
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
        - fromEntities:
            - host
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
      egress:
        - toEndpoints:
            - matchLabels:
                k8s-app: kube-dns
                k8s:io.kubernetes.pod.namespace: kube-system
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
    ```

??? example "customers-service-netpol.yaml"
    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: customers-service
      namespace: petclinic
    spec:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: customers-service
      ingress:
        - fromEndpoints:
            - matchLabels:
                app.kubernetes.io/name: api-gateway
          toPorts:
            - ports:
                - port: "8081"
                  protocol: TCP
        - fromEntities:
            - host
          toPorts:
            - ports:
                - port: "8081"
                  protocol: TCP
      egress:
        - toEndpoints:
            - matchLabels:
                k8s-app: kube-dns
                k8s:io.kubernetes.pod.namespace: kube-system
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: discovery-server
          toPorts:
            - ports:
                - port: "8761"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: config-server
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
    ```

??? example "vets-service-netpol.yaml"
    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: vets-service
      namespace: petclinic
    spec:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: vets-service
      ingress:
        - fromEndpoints:
            - matchLabels:
                app.kubernetes.io/name: api-gateway
          toPorts:
            - ports:
                - port: "8083"
                  protocol: TCP
        - fromEntities:
            - host
          toPorts:
            - ports:
                - port: "8083"
                  protocol: TCP
      egress:
        - toEndpoints:
            - matchLabels:
                k8s-app: kube-dns
                k8s:io.kubernetes.pod.namespace: kube-system
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: discovery-server
          toPorts:
            - ports:
                - port: "8761"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: config-server
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
    ```

??? example "visits-service-netpol.yaml"
    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: visits-service
      namespace: petclinic
    spec:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: visits-service
      ingress:
        - fromEndpoints:
            - matchLabels:
                app.kubernetes.io/name: api-gateway
          toPorts:
            - ports:
                - port: "8082"
                  protocol: TCP
        - fromEntities:
            - host
          toPorts:
            - ports:
                - port: "8082"
                  protocol: TCP
      egress:
        - toEndpoints:
            - matchLabels:
                k8s-app: kube-dns
                k8s:io.kubernetes.pod.namespace: kube-system
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: discovery-server
          toPorts:
            - ports:
                - port: "8761"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: config-server
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
    ```

??? example "api-gateway-netpol.yaml"
    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: api-gateway
      namespace: petclinic
    spec:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: api-gateway
      ingress:
        - fromEntities:
            - host
            - world
            - ingress
          toPorts:
            - ports:
                - port: "8080"
                  protocol: TCP
      egress:
        - toEndpoints:
            - matchLabels:
                k8s-app: kube-dns
                k8s:io.kubernetes.pod.namespace: kube-system
          toPorts:
            - ports:
                - port: "53"
                  protocol: UDP
                - port: "53"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: discovery-server
          toPorts:
            - ports:
                - port: "8761"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: config-server
          toPorts:
            - ports:
                - port: "8888"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: customers-service
          toPorts:
            - ports:
                - port: "8081"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: vets-service
          toPorts:
            - ports:
                - port: "8083"
                  protocol: TCP
        - toEndpoints:
            - matchLabels:
                app.kubernetes.io/name: visits-service
          toPorts:
            - ports:
                - port: "8082"
                  protocol: TCP
    ```

??? example "petclinic-ingress.yaml"
    `${WS_USER}` needs resolving to your own username before this applies cleanly — the
    heredoc in section 5 does that for you automatically.
    ```yaml
    apiVersion: networking.k8s.io/v1
    kind: Ingress
    metadata:
      name: petclinic
      namespace: petclinic
    spec:
      ingressClassName: cilium
      rules:
        - http:
            paths:
              - path: /
                pathType: Prefix
                backend:
                  service:
                    name: ${WS_USER}-petclinic-srv
                    port:
                      number: 8080
    ```

??? example "Final Cilium Helm values, end of this module"
    The literal, live-confirmed output of `helm get values cilium -n kube-system` at the end
    of this module — reached through the two incremental `helm upgrade --reuse-values` calls
    in sections 4 and 5, not applied as one file:
    ```yaml
    ingressController:
      enabled: true
      loadbalancerMode: dedicated
    k8sServiceHost: 192.168.49.2
    k8sServicePort: 8443
    kubeProxyReplacement: true
    operator:
      replicas: 1
    ```

---

## ✅ Module checkpoint

Run the verification script:

```bash
~/k8s-otel-workshop/scripts/verify-fw1b.sh
```

<details>
<summary>What it checks</summary>

1. Cilium reports `OK` (`cilium status --wait`)
2. All six `CiliumNetworkPolicy` objects exist and are `VALID`
3. The `kube-proxy` DaemonSet is at `0` desired / `0` current
4. The `petclinic` `Ingress` resource exists with `ingressClassName: cilium`
5. Its backing Service has a real, non-placeholder NodePort (not `0`, not `<pending>`)
6. A `curl` through that NodePort returns `HTTP 200`
</details>

---

## Troubleshooting

??? failure "Ingress `curl` returns nothing, or connection refused, while kube-proxy is still running"
    This is the `KUBE-EXTERNAL-SERVICES ... REJECT` symptom from section 4's danger box —
    look for it directly before assuming anything about Cilium or the `Ingress` resource is
    wrong:
    ```bash
    minikube ssh -- sudo iptables-save -t filter | grep KUBE-EXTERNAL-SERVICES
    ```
    A `REJECT` rule with `--reject-with icmp-port-unreachable` there means kube-proxy's own
    iptables chain is intercepting the traffic before Cilium's rules run — proceed to
    section 4's kube-proxy replacement; there's nothing to fix on the Ingress side yet.

??? failure "`helm upgrade --wait` returned success, but nothing changed"
    A recurring theme in this module, worth internalizing: Helm's own exit status is **not**
    reliable evidence that a real rollout happened. During testing, `--wait` reported success
    while the Cilium DaemonSet's pods were still running under the *previous* config. Check
    pod **age**, not Helm's exit code:
    ```bash
    kubectl get pods -n kube-system -l k8s-app=cilium -o wide
    ```
    A pod older than the `helm upgrade` you just ran didn't actually restart under the new
    values — force it:
    ```bash
    kubectl rollout restart daemonset/cilium -n kube-system
    kubectl rollout status daemonset/cilium -n kube-system --timeout=180s
    ```
    Then re-check `cilium status --wait` and `helm get values cilium -n kube-system` before
    trusting anything downstream of the upgrade.

??? failure "Ingress `curl` gets a real response, but it's a `503`, and `cilium-dbg bpf lb list` shows `0.0.0.0:0` for your NodePort"
    This is the `shared`-vs-`dedicated` `loadbalancerMode` gap from section 5's danger box,
    not a broken `Ingress` resource or a broken `api-gateway`. Confirm it directly:
    ```bash
    kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list | grep <your-nodeport>
    ```
    A `0.0.0.0:0` backend on an otherwise-correct-looking frontend entry is the signature.
    The fix is the Helm value, not the manifest:
    ```bash
    helm upgrade cilium cilium/cilium --version 1.20.1 --namespace kube-system \
      --reuse-values --set ingressController.loadbalancerMode=dedicated
    ```
    Re-check the same `cilium-dbg bpf lb list` command afterward — you're looking for
    `[NodePort, l7-load-balancer] (L7LB Proxy Port: 19171)` in place of the `0.0.0.0:0` entry.

??? failure "Ingress reaches Envoy fine, but `api-gateway` returns `503`"
    See section 5's second danger box — this is the `reserved:ingress` identity gap. Confirm
    with Hubble, then add `ingress` to `api-gateway`'s `fromEntities` list and re-apply:
    ```bash
    kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
      --to-pod api-gateway --verdict DROPPED -n 10
    ```

??? failure "A `CiliumNetworkPolicy` applied cleanly (`VALID: True`) but traffic still drops"
    `VALID: True` only means the YAML itself is syntactically and schema-correct — it says
    nothing about whether the rule matches the traffic you actually have. Check the real
    source identity with Hubble before editing the policy:
    ```bash
    kubectl -n kube-system exec ds/cilium -- hubble observe --namespace petclinic \
      --to-pod <service> --verdict DROPPED -n 20 -o json | jq '.source.labels, .source.identity'
    ```
    If it comes back `reserved:host` where you expected a real pod identity (or vice versa),
    see section 1's danger box — Service-mediated traffic's identity is genuinely not
    uniform, and both cases usually need an entry.

---

**Next:** [Foundational Workshop #2 — Collecting logs with OpenTelemetry](../02-foundational-2/index.md)
