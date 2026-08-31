# Foundational Workshop #1 — Containers and Kubernetes

**Duration:** ~1.5 hours · **Prerequisite:** [Host setup](../00-setup/index.md) complete

In this module you'll turn a Java web application into a container image, deploy it
into a Kubernetes cluster, expose it to the outside world, and switch on the Kubernetes
audit log — the security trail that Foundational Workshop #2 will start collecting.

By the end you will have:

- [x] A running single-node Kubernetes cluster with API auditing enabled
- [x] One of PetClinic's six services built from source, the rest pulled pre-built
- [x] That service packaged as a container image
- [x] All six services deployed to Kubernetes, reachable from your browser through one gateway

## The six services

Three own data, three don't. Worth knowing before any of them exist as containers:

| Service | Owns | Database |
|---|---|---|
| `customers-service` | Owners and their pets | Own in-memory HSQLDB instance |
| `vets-service` | The list of vets and their specialties | Own in-memory HSQLDB instance |
| `visits-service` | Visit records — each time a pet saw a vet | Own in-memory HSQLDB instance |
| `api-gateway` | Routes external requests to the right backend by path, serves the AngularJS SPA's static files | none |
| `discovery-server` | Eureka service registry — every other service registers here on startup and heartbeats so it can be found by name | none |
| `config-server` | Serves externalized configuration to every other service, once, at startup | none |

!!! abstract "Learning moment — database *per* service, not one shared database"
    `customers-service`, `vets-service` and `visits-service` each get their **own**
    in-memory database — not three services pointed at one shared instance. That's a
    deliberate microservices pattern, not an accident of the in-memory choice: a shared
    database is exactly the kind of coupling this architecture exists to avoid. One
    service's schema change can't break another's queries if there's no schema for them
    to share, and any one of the three can be scaled, restarted, or replaced without
    touching the other two's data at all.

    `api-gateway`, `discovery-server` and `config-server` don't own data — they coordinate
    the other three (routing, service discovery, configuration) without persisting
    anything themselves.

## Session variables

Every command below uses these. Host setup step 13 wired them into the `splunk` account's
`.profile`, so a login shell loads them for you. Confirm that in **each** terminal you use —
including the second one you'll open for load testing:

```bash
echo "$WS_USER on $LOCAL_IP ($PUB_DNS)"
```

!!! warning "Empty output means every later command is subtly wrong"
    If that prints ` on  ()`, nothing is loaded. `source ~/.workshop-env` fixes the current
    shell. It matters more than it looks: with `WS_USER` unset,
    `docker build --tag ${WS_USER}/petclinic-otel:v1` builds `/petclinic-otel:v1` and the
    Deployment then can't find its image. Nothing errors at the point you make the mistake.
    Run that `echo` after every reconnect.

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

## 1. Verify your toolchain

Log in as the `splunk` user. Everything in this workshop runs as `splunk` — the cluster,
the application, and Splunk Enterprise all live under that account.

```bash
ssh -i <your-key.pem> splunk@<your-instance>   # from your laptop
sudo -i -u splunk                              # or from an existing ubuntu session
whoami
```

Confirm the three tools are on your path:

```bash
minikube version
kubectl version --client -o json | jq -r .clientVersion.gitVersion
helm version --short
```

<details>
<summary>Expected output</summary>

```
minikube version: v1.38.1
v1.36.3
v4.2.4+g3900f43
```

`kubectl` may print `The connection to the server localhost:8080 was refused` — that's
expected. There's no cluster yet.
</details>

---

## 2. Start Kubernetes

!!! abstract "Learning moment — what minikube actually is"
    minikube runs a complete single-node Kubernetes cluster inside a **Docker container**
    on your host. The `--driver=docker` flag selects that approach.

    That detail matters later: the cluster has its own container image store, separate
    from your host's. When you build the PetClinic image, you'll build it *into*
    minikube's store so Kubernetes can find it without a registry.

```bash
minikube config set driver docker
minikube start \
  --driver=docker \
  --container-runtime=docker \
  --subnet=192.168.49.0/24
```

!!! warning "Why `--container-runtime=docker` is explicit"
    From minikube v1.39 the default runtime becomes `containerd`. This workshop builds
    images directly into minikube's Docker daemon, so we pin the runtime rather than
    depending on the default of whichever version you installed.

Check the cluster is up:

```bash
minikube status
kubectl get nodes
```

<details>
<summary>Expected output</summary>

```
minikube
type: Control Plane
host: Running
kubelet: Running
apiserver: Running
kubeconfig: Configured

NAME       STATUS   ROLES           AGE   VERSION
minikube   Ready    control-plane   61s   v1.35.1
```

If `STATUS` shows `NotReady`, wait 30 seconds and re-run — the network plugin takes a
moment to initialise.
</details>

---

## 3. Turn on the Kubernetes audit log

!!! abstract "Learning moment — why the audit log matters"
    The Kubernetes API server can record **every request made against the cluster**: who
    made it, what they asked for, and whether it was allowed. That's the primary evidence
    source for detecting a compromised cluster.

    minikube does not enable auditing by default. You'll switch it on now, and in
    Foundational Workshop #2 you'll ship those events to Splunk and search them.

Create an audit policy. This one logs every request at `Metadata` level — fine for a lab,
far too much for production.

```bash
mkdir -p ~/.minikube/files/etc/ssl/certs
cat > ~/.minikube/files/etc/ssl/certs/audit-policy.yaml <<'YAML'
# Log all requests at the Metadata level.
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
YAML

cat ~/.minikube/files/etc/ssl/certs/audit-policy.yaml
```

Restart the cluster with auditing enabled. `audit-log-path=-` sends audit records to the
API server's stdout, where a log collector can pick them up.

```bash
minikube stop
minikube start \
  --driver=docker \
  --container-runtime=docker \
  --subnet=192.168.49.0/24 \
  --extra-config=apiserver.audit-policy-file=/etc/ssl/certs/audit-policy.yaml \
  --extra-config=apiserver.audit-log-path=-
```

### ✅ Checkpoint

```bash
kubectl logs kube-apiserver-minikube -n kube-system \
  | grep -c 'audit.k8s.io/v1'
```

A number greater than zero means auditing is on. If you get `0`, the policy file didn't
reach the node — re-check the path in the `--extra-config` flag.

---

## 4. Build one service — and pull the rest

!!! abstract "Learning moment — six services, not one"
    PetClinic ships two ways upstream: a single Spring Boot monolith, and
    `spring-petclinic-microservices` — six independent Spring Boot services (a config
    server, a Eureka discovery server, an API gateway, and three business services)
    that together are one application. We're using the second, because a monolith gives
    Advanced Workshop #1's service map and Advanced Workshop #2's APM correlation almost
    nothing to show — a single box on a diagram. Six services talking to each other is
    what those tools are actually for.

    You'll build **one** of the six by hand — `customers-service` — for the same reason
    FW #1 has always built PetClinic from source: so you've done it once, and know what's
    inside the image. The other five are pulled pre-built. Building all seven Maven
    modules on every participant's instance buys nothing pedagogically and costs real
    minutes against this module's clock.

```bash
mkdir -p ~/k8s_workshop/petclinic
cd ~/k8s_workshop/petclinic
git clone --branch v3.2.0 --depth 1 \
  https://github.com/spring-petclinic/spring-petclinic-microservices.git
cd spring-petclinic-microservices
```

!!! warning "v3.2.0, not the newest tag"
    v3.4.1 adds a seventh service, `genai-service`, that calls out to OpenAI and needs an
    `OPENAI_API_KEY` — a credential this workshop has no way to hand every participant.
    v3.2.0 is the newest tag without it, on the same Java 17 / Spring Boot 3.x runtime.

Build just `customers-service`. `-am` ("also make") pulls in the shared parent POM it
depends on, without building the other five modules:

```bash
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
./mvnw -B -DskipTests -pl spring-petclinic-customers-service -am package
```

Recorded: a clean build, dependencies included, took 21 seconds.

Find the jar that was produced, the same way as always:

```bash
cd spring-petclinic-customers-service/target
JAR=$(ls -1 *.jar | grep -v 'sources\|javadoc\|original' | head -1)
echo "$JAR"
```

!!! danger "Don't skip straight to running this jar"
    Unlike the old monolith, `customers-service` is a **Spring Cloud Config Client** — at
    startup it tries to fetch its configuration (including which port to listen on) from
    `config-server`, which doesn't exist yet at this point in the module. Run it standalone
    now and it either hangs retrying or fails outright, depending on what's reachable at
    `localhost:8888`. That isn't a build problem — it's the price of six services that
    genuinely depend on each other instead of one that doesn't. The checkpoint below tests
    what's actually testable at this point: that the jar exists and is a real archive.

### ✅ Checkpoint — the jar exists

```bash
unzip -l "$JAR" | grep -c 'BOOT-INF/classes/'
```

A number greater than zero means Maven produced a real, populated Spring Boot fat jar.
The first genuine "does this thing work" test comes after §6, once `config-server` and
`discovery-server` are actually running for it to talk to.

---

## 5. Package it as a container image

!!! abstract "Learning moment — why the base image is a JRE"
    A container image should carry only what it needs at runtime. We compiled with a full
    JDK, but running the jar needs only a **Java runtime**, so the image is based on
    `eclipse-temurin:17-jre-noble` — matching the Java version this application targets,
    the same way the monolith's image matched its own.

Point your shell at minikube's Docker daemon. This is the step that makes the image land
where Kubernetes can see it:

```bash
eval $(minikube -p minikube docker-env)
echo "$DOCKER_HOST"          # should print tcp://192.168.49.2:2376
```

Create the `Dockerfile` in the build output directory:

```bash
JARNAME=$(basename "$JAR")

cat > Dockerfile <<EOF
# syntax=docker/dockerfile:1
FROM eclipse-temurin:17-jre-noble
WORKDIR /app
COPY ${JARNAME} ./app.jar
ENV SPRING_PROFILES_ACTIVE=docker
CMD ["java", "-jar", "app.jar"]
EOF

cat Dockerfile
```

!!! danger "The `ENV SPRING_PROFILES_ACTIVE=docker` line is not optional"
    This bit us during testing, and it's worth knowing why. Without it, the application
    starts, logs nothing alarming, and then never becomes reachable — no crash, no error,
    just silence. `customers-service`'s configuration only pins its port to `8081` and
    points it at `discovery-server` under a profile named `docker`. Skip this line and the
    application binds to a **random port** instead, which nothing in the manifest below
    knows to look for. The five pre-built images you're about to pull already bake this in
    — check their upstream `Dockerfile` and you'll find the identical line. This one you
    write yourself, so it's easy to leave out.

Build it:

```bash
docker build --tag ${WS_USER}/petclinic-customers:v1 .
docker images | grep petclinic-customers
```

### ✅ Checkpoint

```bash
docker images --format '{{.Repository}}:{{.Tag}}' | grep "^${WS_USER}/petclinic-customers:v1$"
```

The tag echoing back means the image exists inside minikube's store. Recorded size:
348 MB, against 491 MB for the equivalent pre-built image upstream ships — the same
JRE-vs-JDK saving as before, this time without a layered/extracted jar.

---

## 6. Deploy to Kubernetes

!!! abstract "Learning moment — six Deployments, one namespace, one entry point"
    Each service gets its own **Deployment** — its own restart policy, its own
    readiness check — and its own **Service** for the others to find it by name.
    Only `api-gateway`'s Service is a `NodePort`; the other five stay `ClusterIP`,
    reachable inside the cluster but not from outside it. That mirrors how you'd run this
    in production: one ingress point, everything else internal.

    All six live in their own **`petclinic` namespace**, not `default`. The application
    is one unit — being able to `kubectl get all -n petclinic` or
    `kubectl delete namespace petclinic` as a single step is worth having, the same way
    you'd want it in a cluster shared with other workloads. This module still uses
    `kubectl ... -n petclinic` explicitly on every command below rather than switching
    your shell's default namespace — later modules assume `default` for things unrelated
    to PetClinic, and a silently-changed default would make those commands fail for a
    reason that isn't obvious from the error.

Download the manifest and substitute your username:

```bash
mkdir -p ~/k8s_workshop/petclinic/k8s_deploy
cd ~/k8s_workshop/petclinic/k8s_deploy

curl -fsSL -o petclinic.yml.tmpl \
  https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop-2026/main/labs/manifests/petclinic-microservices.yml

WS_USER=$WS_USER envsubst < petclinic.yml.tmpl > ${WS_USER}-petclinic-k8s-manifest.yml
```

!!! note "Skim it before applying — four things are worth spotting"
    - A **`Namespace`** object, `petclinic`, first in the file. One `kubectl apply -f`
      creates it and everything inside it together — nothing extra to run beforehand.
    - A **`ConfigMap`** holding six small YAML files, copied from
      `spring-petclinic-microservices-config` upstream. Without it, `config-server` would
      default to fetching this same configuration live from GitHub on every restart — an
      external, unpinned dependency this workshop otherwise never has. The manifest bakes
      the files in instead; see its header comment for the full reasoning.
    - Five of six Deployments carry an **`initContainer`** that polls
      `config-server:8888/actuator/health` in a loop before the real container starts.
      `customers-service` and its four siblings are Config Clients — they fail fast if
      `config-server` isn't answering yet, and without this gate you'd see every one of
      them crash-restart twice in the first two minutes before settling. The gate makes
      that invisible instead of alarming.
    - The six internal Service names (`config-server`, `discovery-server`, and so on)
      are **not** prefixed with your username, unlike everything else in this workshop.
      They never leave your own cluster, and the pre-built images have those exact
      hostnames baked into their configuration — renaming them would mean overriding
      that wiring for no real benefit.

Apply it:

```bash
kubectl apply -f ${WS_USER}-petclinic-k8s-manifest.yml
kubectl rollout status deployment/config-server     -n petclinic --timeout=180s
kubectl rollout status deployment/discovery-server   -n petclinic --timeout=180s
kubectl rollout status deployment/customers-service  -n petclinic --timeout=180s
kubectl rollout status deployment/visits-service     -n petclinic --timeout=180s
kubectl rollout status deployment/vets-service       -n petclinic --timeout=180s
kubectl rollout status deployment/api-gateway        -n petclinic --timeout=180s
```

!!! note "Recorded timing"
    Tested end to end on an 8 vCPU / 32 GB instance: all six `Ready`, zero restarts, in
    72 seconds. `config-server` first is deliberate — everything else waits on it, so if
    a `rollout status` call above it hangs, that's where to look.

!!! danger "4 vCPU is not enough for this module, full stop"
    This was tested, not assumed: on a 4 vCPU / 16 GB instance, six services cold-starting
    at once drove load average to 66 and the **kubelet missed its node-lease renewal**.
    Kubernetes marked the node `NotReady` and evicted every pod on it — this application
    included, not just the new services. It recovered on its own in under a minute, but in
    a room of twenty people it reads as "the lab broke," all at once. If `minikube status`
    or `kubectl get nodes` shows anything but `Ready` during this step, that's what's
    happening — it is not a sign anything is misconfigured.

Inspect what you created:

```bash
kubectl get all -n petclinic
```

---

## 7. Reach the application

```bash
minikube ip
curl -s -o /dev/null -w '%{http_code}\n' http://$(minikube ip):30000/
```

The hostname `minikube` was mapped to that IP during host setup, so this also works:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://minikube:30000/
```

!!! note "A 503 here that clears on retry is not a bug"
    `api-gateway` routes requests by asking `discovery-server` who's currently running —
    but it caches that answer for up to 30 seconds after it first asks. Reach it in the
    few seconds between "all pods Ready" and that first cache fill, and you'll see
    `HTTP 503` on an API route even though everything registered correctly. Retry once,
    a few seconds later. `curl http://minikube:30000/` (the root path, serving the SPA
    directly rather than through a routed API call) is unaffected and is what the
    checkpoint above actually tests.

### Now open it in a browser

`200` proves the Service answers. Actually looking at the application is the point — you're
about to spend four modules observing it.

!!! abstract "Learning moment — why this needs a tunnel and Splunk Web doesn't"
    `minikube ip` returned `192.168.49.2`: an address on the Docker network *inside* this
    host. The NodePort publishes PetClinic on port 30000 of **that** address, not of the EC2
    instance — so it is unreachable from your laptop no matter what the security group says.
    Opening port 30000 would do nothing.

    Splunk Enterprise is the opposite. It runs directly on the host and binds `0.0.0.0:8000`,
    which is why `http://$PUB_DNS:8000` opens with no forwarding at all.

    | | Runs on | Listens on | From your laptop |
    |---|---|---|---|
    | Splunk Web `:8000` | the EC2 host | `0.0.0.0:8000` | direct |
    | PetClinic `:30000` | inside Kubernetes | NodePort on `192.168.49.2` | tunnel required |

    That distinction is the whole point of a NodePort: it exposes a Service on the *node*,
    and here the node is a container, not the machine you rented.

From a terminal **on your laptop** — not on the instance:

```bash
ssh -i <your-key.pem> -L 8080:192.168.49.2:30000 splunk@<your-instance>
```

Leave it connected and open **<http://localhost:8080>**. `ssh -L` resolves `192.168.49.2` on
the remote side, so it reaches the NodePort directly — nothing extra runs on the instance,
and the same command works in PowerShell or Windows Terminal.

![PetClinic welcome page](../assets/img/01-fw1/image13.png)
<!-- STATUS: pending-recapture · 2023 · replace with 4.0.0-SNAPSHOT UI -->

??? tip "Alternative — `kubectl port-forward`, which proves the pod is serving"
    More Kubernetes-native, and it tells you something the NodePort doesn't: the API server
    forwards straight through to a pod, so a page here means the container itself is healthy
    rather than that the Service happens to route.

    ```bash
    # on the instance, as splunk — leave it running
    kubectl port-forward -n petclinic svc/${WS_USER}-petclinic-srv 8080:8080
    ```

    ```bash
    # from your laptop, in a second terminal
    ssh -i <your-key.pem> -L 8080:localhost:8080 splunk@<your-instance>
    ```

    Same URL, <http://localhost:8080>. Adding `--address 0.0.0.0` to the port-forward would
    publish it on the host's public interface instead — that works too, but it needs 8080
    open in the security group, and the tunnel doesn't.

    !!! warning "Close your other tunnel first"
        Both routes use **8080 on your laptop**, so they collide. If the NodePort tunnel
        from host setup is still open, this second `ssh -L` fails with
        `bind: Address already in use`. Close the first one, or forward to a different
        local port — `-L 8081:localhost:8080`, then browse
        <http://localhost:8081>.

        Only the number left of the colon is yours to choose; it is the port on your
        laptop, not a port anyone opens on the instance.

Click around — find owners, add a pet, look at the veterinarians list. Then click
**ERROR** in the menu bar. That deliberately throws an exception, and in the next module
you'll find the resulting stack trace in Splunk.

---

## ✅ Module checkpoint

Run the verification script:

```bash
~/k8s-otel-workshop/scripts/verify-fw1.sh
```

<details>
<summary>What it checks</summary>

1. minikube node is `Ready`
2. API server is emitting audit events
3. `minikube` resolves via `/etc/hosts`
4. The `customers-service` image exists in minikube's Docker store
5. Each of the six Deployments has an available replica
6. At least four services are registered in Eureka
7. `config-server` is serving from the local ConfigMap, not reaching out to GitHub
8. The gateway answers `HTTP 200` on NodePort 30000
9. A request routed through the gateway reaches `vets-service`
</details>

---

## Troubleshooting

??? failure "`kubectl get nodes` says `NotReady`"
    Usually the CNI plugin needing a moment after start — wait 30 seconds. But if this
    happens **during or right after §6** on anything smaller than 8 vCPU / 32 GB,
    it's the six-service cold start hitting the instance's ceiling, not a transient
    blip — see the warning in §6. Give it a minute to self-recover before assuming
    anything is broken; if it doesn't, `minikube delete && minikube start ...` with the
    flags from step 2.

??? failure "`docker build` can't find the jar"
    You're probably in the wrong directory. The `Dockerfile` and the jar must both be in
    `~/k8s_workshop/petclinic/spring-petclinic-microservices/spring-petclinic-customers-service/target`.

??? failure "Pod status is `ErrImageNeverPull` or `ImagePullBackOff` (for `customers-service`)"
    The image wasn't built into minikube's Docker daemon. Re-run
    `eval $(minikube -p minikube docker-env)` and rebuild — `docker images` must list
    `${WS_USER}/petclinic-customers:v1` *after* that eval. The other five services pull
    from Docker Hub and don't hit this — if one of *those* shows `ImagePullBackOff`
    instead, it's a network problem reaching `hub.docker.com`, not a local build issue.

??? failure "A service (not `customers-service`) is stuck `0/1 Running`, never `1/1`"
    Check its `initContainer` first — `kubectl describe pod -n petclinic <name>` shows
    whether it's still stuck in `Init:0/1`, waiting on `config-server`. If `config-server`
    itself never became `Ready`, every other service waits on it forever; that's the one
    deployment worth checking before any other. If the init container finished but the
    main container's readiness probe is still failing, `kubectl logs -n petclinic <pod>`
    — a `ConnectException` there usually means `SPRING_PROFILES_ACTIVE=docker` didn't
    reach the container (only possible for your hand-built `customers-service` image).

??? failure "`http://localhost:8080` refuses the connection in your browser"
    The tunnel isn't up, or it's pointed at the wrong place. Check, in order: the `ssh -L`
    command is running in a terminal **on your laptop** (not on the instance); the target is
    `192.168.49.2:30000`, minikube's address, not `localhost:30000`; and
    `curl http://minikube:30000/` still returns `200` on the instance. A tunnel to a port
    nothing listens on connects fine and then fails at the first request, so a clean SSH
    login is not evidence that the forward works.

??? failure "`curl http://minikube:30000` fails but the IP works"
    The `/etc/hosts` entry is missing. It's created during host setup and needs root:
    ```bash
    exit                                  # back to the ubuntu user
    echo -e "$(minikube ip)\tminikube" | sudo tee -a /etc/hosts
    ```

---

**Next:** [Foundational Workshop #2 — Collecting logs with OpenTelemetry](../02-foundational-2/index.md)
