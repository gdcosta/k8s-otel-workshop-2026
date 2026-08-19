# Instructor guide

Everything you need to run this workshop for other people: provisioning, timing, the
failure modes participants actually hit, and extra material for when a group moves fast.

Participants don't need this page.

---

## Choosing a format

The four modules are cumulative but individually deliverable. Each ends in a verified state
the next one starts from, so you can stop after any of them.

| Format | Modules | Time | Good for |
|---|---|---|---|
| Foundational | Setup + FW #1 + FW #2 | Half day | Teams new to Kubernetes |
| Advanced | + AW #1 | Full day | Existing Splunk platform users |
| Complete | + AW #2 | Two half-days | Observability Cloud evaluations |
| AW #2 only | Setup → FW #2 pre-built, then AW #2 | 2 hours | Audiences who only care about O11y |

For anything short of the complete series, **pre-build the environment to the starting
state** — see [Fast-forwarding](#fast-forwarding-to-a-later-module). Nobody enjoys watching
Maven download the internet.

---

## Provisioning

### One instance per participant

| | |
|---|---|
| OS | Ubuntu 24.04 LTS, **x86-64** |
| Size | 4 vCPU / 16 GB — AWS `t3.xlarge` |
| Disk | 100 GB gp3 |
| Cost | roughly $0.17/hour on-demand |

!!! danger "ARM will not work"
    Splunk Enterprise has no Linux ARM64 build. This is not a preference.

!!! warning "Budget the downloads"
    Roughly 3 GB per instance during setup — Splunk Enterprise alone is 1.6 GB. Twenty
    participants starting simultaneously is 60 GB of egress and a slow first hour. Build
    the instances **in advance**, or bake an AMI once the setup is verified.

### Security group

| Port | Source | Purpose |
|---|---|---|
| 22 | participant CIDR | SSH |
| 8000 | participant CIDR | Splunk Web |
| 8080 | participant CIDR | PetClinic port-forward |
| 8089 | Splunk O11y realm IPs | AW #2 only — Log Observer Connect |

Outbound: all.

!!! danger "Do not reuse a shared key pair across events"
    Earlier versions of this workshop distributed one key pair to all instructors. A single
    private key that unlocks every instance ever built is not worth the convenience —
    generate one per event and delete it afterwards.

### Building instances

```bash
git clone https://github.com/gdcosta/k8s-otel-workshop-2026.git ~/k8s-otel-workshop
cd ~/k8s-otel-workshop
./scripts/bootstrap.sh
```

Idempotent, reads every version from `versions.env`, and generates a **unique Splunk admin
password per instance** into `~/splunk-admin-password.txt`. Collect those when handing out
credentials — don't set a common one.

Then confirm each instance before anyone arrives:

```bash
sudo -i -u splunk
~/k8s-otel-workshop/scripts/verify-setup.sh      # 12 checks
```

### Fast-forwarding to a later module

To start a group at FW #2 or later, walk the preceding modules once on a single instance,
confirm the state, then **snapshot it as an AMI** and build the rest of the fleet from that.
That's far more reliable than automating a replay, and it means every participant starts
from a state you have personally verified.

```bash
# On the template instance, as the splunk user
export WS_USER=<participant>
source ~/.workshop-env

./scripts/verify-setup.sh     # host ready
./scripts/verify-fw1.sh       # FW1 complete  -> snapshot here to start at FW2
./scripts/verify-fw2.sh       # FW2 complete  -> snapshot here to start at AW1
```

!!! tip "Snapshot at a verified checkpoint, not a hopeful one"
    Take the AMI only after the relevant `verify-*.sh` exits 0. A snapshot of a
    half-configured host reproduces the half-configuration perfectly, for everyone.

!!! warning "Two things to reset in a cloned instance"
    Each clone gets a new hostname and IP, so on first boot:

    ```bash
    source ~/.workshop-env       # LOCAL_IP and PUB_DNS re-derive from instance metadata
    sed -i "s/^export WS_USER=.*/export WS_USER=<participant>/" ~/.workshop-env
    ```

    If you snapshotted after AW #2's Log Observer Connect setup, the TLS certificate carries
    the **template's** hostname and will not match the clone. Regenerate it per instance,
    or snapshot before that step.

---

## Running the session

### Timing

| Module | Scheduled | Realistic |
|---|---|---|
| Host setup | 45 min | pre-build it |
| FW #1 | 1.5 hr | 2 hr with a mixed-ability group |
| FW #2 | 2 hr | 2.5 hr — the Collector config is the densest part |
| AW #1 | 2 hr | 2 hr |
| AW #2 | 2 hr | 2.5 hr if participants create their own O11y trials |

The single biggest time sink is the **first** `./mvnw package` and `docker build`. Warming
the Maven cache and pulling `eclipse-temurin` during setup saves 10–15 minutes per person.

### Set expectations about silent failures

Worth saying out loud at the start, because it shapes how people debug:

> Most misconfigurations in this workshop don't produce errors. Helm succeeds, pods stay
> healthy, and no data arrives. When something doesn't work, don't re-run it — check each
> hop: is the change in the generated config, does the component see it, does the data
> arrive.

The command that resolves most of it:

```bash
kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
  -o go-template='{{index .data "relay"}}'
```

### Verification as a teaching tool

Each module ends with an assertion script. Have participants run them rather than asking
"did it work?" — they self-diagnose, and you see who's stuck without going desk to desk.

```bash
export WS_USER=<their-username> SPLUNK_AUTH=admin:<password>
./scripts/verify-fw2.sh
```

**55 assertions across the five scripts.** They're also what the CI canary runs against new
Collector releases.

---

## Failure modes, ranked by how often they happen

??? failure "`minikube` doesn't resolve — the most common by far"
    The `/etc/hosts` entry is missing. It needs root, and `splunk` has no sudo, so it must
    be done during setup as `ubuntu`. The failure is silent: `sudo tee ... >/dev/null`
    swallows the error and returns 0.

    ```bash
    exit    # back to ubuntu
    echo -e "192.168.49.2\tminikube" | sudo tee -a /etc/hosts
    ```

??? failure "Image built but Kubernetes can't find it"
    They forgot `eval $(minikube -p minikube docker-env)` before building, so the image
    went to the host daemon. `docker images` must list it *after* that eval.

??? failure "Collector deployed, no data in Splunk"
    Almost always HEC. Splunk 10 enables SSL on HEC by default and the workshop uses
    `http://`. Have them test HEC directly with `curl` before looking at the Collector.

??? failure "A config change appears to do nothing"
    Read the generated config (command above). If the change isn't there, the overlay
    didn't apply — usually YAML indentation. If it *is* there but has no effect, an OTTL
    `where` clause isn't matching.

??? failure "Participants on different Collector chart versions"
    Someone omitted `--version`. The chart ships breaking changes on most minor releases.
    Pin it.

??? failure "Out of memory during AW #2"
    By AW #2 the host runs minikube, Splunk, the Collector, PetClinic with a Java agent,
    JMeter and possibly Chromium. 16 GB is comfortable; 8 GB is not.

---

## Bonus material: Kubernetes security detections

The audit log enabled in FW #1 is a genuine security data source. These run against
`k8s_ws_logs` and work with the data the workshop already collects — good for groups that
finish early, or a security-focused audience.

??? example "1 — Sensitive host path mounted into a pod"
    A container mounting `/`, `/etc`, `/var/run/docker.sock` or the kubelet directory can
    usually escape to the node.
    ```
    index="k8s_ws_logs" (sourcetype=kube:object:pods OR sourcetype=kube:objects:pods)
      spec.volumes{}.name=* TERM(hostPath) TERM(image)
      spec.volumes{}.hostPath.path IN("/proc", "/var/run/docker.sock", "/", "/etc", "/root",
        "/var/run/crio/crio.sock", "/var/lib/kubelet", "/var/lib/docker/overlay2",
        "/var/lib/kubelet/pki", "/etc/kubernetes", "/etc/kubernetes/manifests")
    | fields _time metadata.namespace spec.containers{}.name spec.serviceAccount
             spec.volumes{}.hostPath.path spec.containers{}.image
    ```

??? example "2 — Cluster scan detection"
    Anonymous requests across many endpoints — the signature of a scanner.
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      "user.username"="system:anonymous"
    | rename sourceIPs{} as src_ip
    | stats count min(_time) as firstTime max(_time) as lastTime
            values(responseStatus.code) as codes values(userAgent) as agents
            values(verb) as verbs values(requestURI) as uris
        by src_ip, "user.username", "user.groups{}"
    | convert timeformat="%Y-%m-%dT%H:%M:%S" ctime(firstTime) ctime(lastTime)
    ```

??? example "3 — Pod enumeration"
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      "user.username"="system:anonymous" verb=list objectRef.resource=pods
      requestURI="/api/v1/pods"
    | rename sourceIPs{} as src_ip
    | stats count values(responseStatus.code) values(userAgent) by src_ip, "user.username"
    ```

??? example "4 — Access to secrets or configmaps from outside the cluster"
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      (objectRef.resource=secrets OR objectRef.resource=configmaps)
      sourceIPs{}!=::1 sourceIPs{}!=127.0.0.1
    | table sourceIPs{}, "user.username", "user.groups{}", objectRef.resource,
            objectRef.namespace, objectRef.name
    | dedup "user.username", "user.groups{}"
    ```

??? example "5 — Busiest service accounts"
    Establishes a baseline. A service account suddenly touching far more pods is worth a look.
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      user.groups{}=system:serviceaccounts objectRef.resource=pods
    | top sourceIPs{}, "user.username", verb, "annotations.authorization.k8s.io/decision"
    ```

??? example "6 — ClusterRole and binding access"
    Privilege escalation usually passes through here.
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      (objectRef.resource=clusterroles OR objectRef.resource=clusterrolebindings)
      sourceIPs{}!=::1 sourceIPs{}!=127.0.0.1
    | table sourceIPs{}, "user.username", "user.groups{}", objectRef.namespace, requestURI
    | dedup "user.username", "user.groups{}"
    ```

??? example "7 — Service accounts being denied"
    A burst of `Failure` for one account often means compromised credentials probing.
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      user.groups{}=system:serviceaccounts "responseStatus.status"=Failure
    | table sourceIPs{}, "user.username", userAgent, verb, "responseStatus.status", requestURI
    ```

??? example "8 — Anonymous kubectl from off-cluster"
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      userAgent=kubectl* sourceIPs{}!=127.0.0.1 sourceIPs{}!=::1
      "user.username"=system:anonymous
    | rename sourceIPs{} as src_ip
    | stats count by src_ip, "user.username", verb, userAgent, requestURI
    ```

??? example "9 — Known scanner images being pulled"
    kube-hunter and kube-bench are legitimate tools. Nobody should be pulling them into
    your cluster unannounced.
    ```
    index="k8s_ws_logs" sourcetype=kube:object:events
      object.message IN ("Pulling image *kube-hunter*", "Pulling image *kube-bench*",
                         "Pulling image *kube-recon*")
    | rename object.* AS *, involvedObject.* AS *, source.host AS host
    | eval phase="operate", severity="high"
    | stats min(_time) as firstTime max(_time) as lastTime count
        by host, name, namespace, kind, reason, message, phase, severity
    | convert timeformat="%Y-%m-%dT%H:%M:%S" ctime(firstTime) ctime(lastTime)
    ```

!!! tip "Demonstrating detection #2 live"
    Anonymous requests appear naturally in the audit log — minikube's own health probes
    generate them. Point at what's already there rather than trying to stage an attack.

---

## Bonus material: operational views

??? example "Client tooling by user agent"
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver" earliest=-15m
    | rex field=userAgent "^(?<agent>.*?)(?:\s|$)"
    | stats count by agent | sort -count
    ```

??? example "Pod lifecycle events over time"
    ```
    index="k8s_ws_logs" sourcetype=kube:object:events earliest=-1d@d
    | rename object.* AS *, involvedObject.* AS *
    | timechart count by reason
    ```

??? example "CoreDNS query types"
    ```
    index="k8s_ws_logs" "k8s.cluster.name"="<WS_USER>-minikube-cluster"
      sourcetype="kube:container:coredns" earliest=-1d@d
    | rex field=_raw "\s(?<qtype>[A-Z]+)\s+IN\s"
    | stats count by qtype
    ```

??? example "Response times per endpoint, from access logs alone"
    Only works after FW #2 step 7 enables access logging.
    ```
    index=k8s_ws_petclinic_logs http_duration_us=*
    | eval ms=round(http_duration_us/1000, 1)
    | stats count, round(avg(ms),1) as avg_ms, round(p95(ms),1) as p95_ms by http_path
    | sort -count
    ```

---

## Teardown

Between deliveries, reset an instance without rebuilding it:

```bash
helm uninstall ${WS_USER}-k8s-ws
kubectl delete -f ~/k8s_workshop/petclinic/k8s_deploy/${WS_USER}-petclinic-k8s-manifest.yml
minikube delete
docker system prune -af
```

Splunk indexes keep growing — the audit log is deliberately verbose:

```bash
/opt/splunk/bin/splunk clean eventdata -index k8s_ws_logs -f
```

When the event is over, **terminate the instances and revoke the tokens**. Observability
Cloud ingest and RUM tokens are organisation-level credentials; they shouldn't outlive the
workshop.

---

## Keeping the material working

**Watch the chart canary.** The Collector chart ships breaking changes on most minor
releases. `.github/workflows/chart-canary.yml` tests the next version weekly and opens an
issue when it breaks. Check for open `chart-drift` issues before committing to a delivery
date.

**Re-run the verification suite** against a fresh instance before each event. It takes
minutes and catches upstream drift that would otherwise surface mid-session.

**Version pins** all live in `versions.env`. Change them there and nowhere else.
