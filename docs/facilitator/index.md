# Facilitator guide

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
| 22 | **the participant's own IP** | SSH — and every browser tunnel |
| 8000 | **the participant's own IP** | Splunk Web — see the warning below |
| 8080 | *not required* | see the note below — the tunnel makes this unnecessary |
| 8089 | Splunk O11y realm IPs | AW #2 only — Log Observer Connect |

Outbound: all.

!!! danger "Port 8000 must be restricted to the participant's own IP — the admin password is published"
    Splunk Web binds `0.0.0.0:8000` on the EC2 host, so with a broad source range the login
    page is reachable from the open internet. Verified from outside AWS during testing.
    Combined with the published `admin` / `Workshop2026!` credential and a predictable
    `ec2-<ip>.<region>.compute.amazonaws.com` hostname, anyone who finds the host can sign
    in as admin. A CIDR covering a whole office or a conference network is not enough — scope
    this rule to the single address each participant is connecting from.

    If you would rather not open 8000 at all, close it and reach Splunk Web over an SSH
    tunnel instead:

    ```bash
    ssh -i <your-key.pem> -L 8000:localhost:8000 splunk@<their-instance>
    ```

    Then browse **http://localhost:8000**. This is the same pattern port 8089 already
    follows — it is open only to the four Observability Cloud realm IPs, never broadly.

    These are throwaway credentials on a disposable lab instance. Say so to the group, and
    make sure nobody carries them to anything real.

!!! note "8080 does not need opening, and 30000 would not help"
    Participants reach PetClinic over an SSH tunnel on port 22. Verified on a running host:
    NodePort **30000 is not bound on the instance's interfaces at all** — it exists only on
    minikube's internal address `192.168.49.2` — so a rule for it would expose nothing.

    Direct exposure needs *two* changes, and either alone does nothing: the port-forward
    must be given `--address 0.0.0.0` (it binds loopback by default), **and** 8080 must be
    opened to the participant's own IP. Prefer the tunnel — no rule, nothing on the
    internet, and it ends with the SSH session.

### Getting keys to participants

**One key pair per event, shared by the room, is the right default.** Generating and
distributing a pair per participant is a real operational burden — chasing twenty people
before an event, tracking which key went where, deleting them afterwards — and it buys far
less than it appears to.

!!! abstract "Why per-participant keys are not worth it here"
    Look at what an SSH key is actually protecting. The Splunk admin password is
    `Workshop2026!` on **every** instance and is printed in the guide. So anyone who can
    reach port 8000 on any box is already admin there, key or no key.

    A per-participant SSH key does not change that. **The security group is the boundary**,
    and it has to be right anyway for exactly the same reason.

    The one thing a shared key does enable is participant A reaching participant B's
    instance over SSH — and scoping port 22 the same way you already scope 8000 removes it.

**So the rule is one rule, applied to both ports:** source each participant's inbound
access to **their own IP**, not to an office or conference CIDR. Same operational step you
are already doing for Splunk Web, extended to 22. If someone's address changes mid-event,
update that one rule.

Then:

- Generate **one key pair for the event**, distribute it as you would any other credential
  — not a shared drive, not the event chat.
- **Delete it afterwards**, and terminate the instances. Both are disposable by design.

??? tip "Higher-assurance options, if your situation allows"
    **Collect public keys in advance.** Ask participants for an SSH public key
    (`ssh-keygen -t ed25519`, send the `.pub` only) and add it at launch. Private keys never
    travel and there is nothing to distribute or clean up. Best security; only workable when
    you have the participant list far enough ahead.

    **Skip keys entirely with AWS Systems Manager.** Session Manager needs no key and no
    inbound port 22 at all, and it supports the port forwarding this workshop depends on via
    `AWS-StartPortForwardingSessionToRemoteHost` — which can target `192.168.49.2:30000`
    directly. The catch is that every participant then needs AWS CLI and IAM credentials,
    which is usually a bigger ask than a `.pem`. Worth it if your organisation already
    runs SSM.

!!! tip "Tell participants which case they are in"
    [Host setup](../00-setup/index.md) documents all three routes — key sent to them, public
    key they supplied, or self-provisioned. Say explicitly which one applies at your event,
    because every `ssh` command in the workshop begins `-i <your-key.pem>` and a participant
    who does not know what to substitute cannot begin at all.

### Building instances

```bash
git clone https://github.com/gdcosta/k8s-otel-workshop-2026.git ~/k8s-otel-workshop
cd ~/k8s-otel-workshop
./scripts/bootstrap.sh
```

Idempotent, reads every version from `versions.env`, and seeds the **fixed workshop
credentials**. There are no per-instance passwords to collect or hand out.

| Account | Credential | Created by |
|---|---|---|
| Splunk admin | `admin` / `Workshop2026!` | `bootstrap.sh`, during host setup |
| Log Observer service account | `loc_svc` / `LogObserver2026!` | AW #2, step 4 |

!!! note "Why these are fixed and published"
    An earlier revision generated a random admin password per instance. In a taught
    workshop the randomness costs more than it buys:

    - **You can help a stuck participant.** With a generated password you cannot predict
      the credential on someone else's box, and screen-sharing to read it back wastes the
      room's time.
    - **Losing the note is no longer fatal.** A participant who closes the terminal that
      printed their password used to be locked out of their own instance mid-module, with
      no recovery path in the guide.
    - **Every command becomes copy-pasteable.** `SPLUNK_AUTH`, the index creation in FW #2,
      the HEC setup, and AW #2's `add user` all carried a `<YOUR_ADMIN_PASSWORD>`
      placeholder. They now carry a literal that works as typed.

    The trade is that the credential is public, which is entirely handled by scoping port
    8000 to the participant's own IP — see the security group section above.

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
export WS_USER=<their-username>
export SPLUNK_AUTH=admin:'Workshop2026!'
./scripts/verify-fw2.sh
```

The single quotes around the password matter — `!` is history expansion in an interactive
`bash` shell. `verify-fw2.sh`, `verify-aw1.sh` and `verify-aw2.sh` all hard-require
`SPLUNK_AUTH` and exit immediately without it.

**55 assertions across the five scripts.** They're also the check to run against a new
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

!!! warning "These searches have been run against live workshop data — keep it that way"
    All 13 searches in this section and the next were executed against a real workshop
    cluster. Two were invalid and one returned a false all-clear; those are fixed or flagged
    inline below. Searches **1** (false negative), **3**, **8** and **9** carry notes
    explaining what an empty result actually means — read them before demonstrating.

    **Any search added here in future must be run against live data before it ships.** SPL
    that looks right frequently isn't, and on this page the failure mode is an audience
    watching a detection quietly return nothing.

??? example "1 — Sensitive host path mounted into a pod ⚠ known false negative"
    A container mounting `/`, `/etc`, `/var/run/docker.sock` or the kubelet directory can
    usually escape to the node.

    !!! warning "Do not present this as a working detection — it currently returns a false all-clear"
        On a live workshop cluster this search returns **zero rows even though the
        workshop's own Collector DaemonSet mounts `/etc` and `/proc`** — two paths on this
        detection's own watchlist. Confirmed with `kubectl` against the running agent pod.

        The SPL is valid and the field is populated; clause isolation pinned the failure to
        the `spec.volumes{}.hostPath.path IN(...)` clause matching nothing:

        ```
        base sourcetype=kube:object:pods              10765
        + spec.volumes{}.name=*                       10518
        + TERM(hostPath)                               7532
        + spec.volumes{}.hostPath.path=*               7285
        + spec.volumes{}.hostPath.path IN("/etc","/proc")   0
        ```

        The indexed `kube:object:pods` records only ever carry a subset of the agent's
        hostPaths — `/var/log`, `/var/lib/docker/containers`, `/var/addon/splunk/otel_pos`
        — and never `/etc` or `/proc`. **This is a data-capture gap in what
        `k8sObjects: pods` collects, not a query defect.**

        **An empty result here means nothing.** It is not evidence that no sensitive host
        paths are mounted. Use it to teach the *shape* of the detection, and say plainly
        that it needs investigation before anyone relies on it. Do not use it as a negative
        finding in front of an audience — a security detection that reads clean on a dirty
        cluster teaches people to trust a false negative.

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
    Zero rows is the expected, healthy result on a workshop cluster — nothing has enumerated
    it. Show the query and what it *would* catch; don't treat the empty table as a fault.

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
    Like #3, zero rows is the expected result here — the anonymous requests in the audit log
    all come from minikube's own loopback health probes, which this search deliberately
    excludes. An empty table means the cluster is clean, not that the search is broken.

    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver"
      userAgent=kubectl* sourceIPs{}!=127.0.0.1 sourceIPs{}!=::1
      "user.username"=system:anonymous
    | rename sourceIPs{} as src_ip
    | stats count by src_ip, "user.username", verb, userAgent, requestURI
    ```

??? example "9 — Known scanner images being pulled"
    kube-hunter and kube-bench are legitimate tools. Nobody should be pulling them into
    your cluster unannounced. Zero rows is the expected result on a workshop cluster.

    !!! note "The wildcard warning on this one is expected"
        Every run prints `WARN: The term '"object.message"="Pulling image *kube-bench*"'
        contains a wildcard in the middle of a word or string.` That is Splunk noting the
        leading/trailing wildcards can't use the index efficiently. The search is correct
        and the warning is harmless — say so before someone asks.

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

Validated against live workshop data alongside the security detections above — same rule
applies: run anything new here before shipping it.

??? example "Client tooling by user agent"
    ```
    index="k8s_ws_logs" sourcetype="kube:container:kube-apiserver" earliest=-15m
    | rex field=userAgent "^(?<agent>.*?)(?:\s|$)"
    | stats count by agent | sort -count
    ```

??? example "Pod lifecycle events over time"
    `earliest=-4h`, not `-1d@d` — the day-snapped version prints a full day of zero-count
    rows before any real data appears.

    ```
    index="k8s_ws_logs" sourcetype=kube:object:events earliest=-4h
    | rename object.* AS *, involvedObject.* AS *
    | timechart count by reason
    ```

??? example "CoreDNS query types"
    The query type is preceded by a **double quote**, not whitespace — `\s` before the
    capture never matches. A real CoreDNS line:
    ```
    [INFO] 10.244.0.1:51939 - 16000 "AAAA IN ingest.us1.observability.splunkcloud.com. udp 69 false 1232" NOERROR qr,rd,ra 303 0.004842068s
    ```

    Match the quote instead:

    ```
    index="k8s_ws_logs" "k8s.cluster.name"="${WS_USER}-minikube-cluster"
      sourcetype="kube:container:coredns" earliest=-1d@d
    | rex field=_raw "\"(?<qtype>[A-Z]+)\s+IN\s"
    | stats count by qtype
    ```

    Expected shape — a roughly even split between `A` and `AAAA` lookups:
    ```
    qtype count
    A      1950
    AAAA   1950
    HINFO     1
    ```

??? example "Response times per endpoint, from access logs alone"
    Only works after FW #2 step 7 enables access logging. Note the rounding happens in a
    second `eval` **after** `stats` — `stats` rejects an eval function wrapping an aggregate
    (`round(avg(ms),1)` is a FATAL error, not a warning).

    ```
    index=k8s_ws_petclinic_logs http_duration_us=*
    | eval ms=http_duration_us/1000
    | stats count, avg(ms) as avg_ms, p95(ms) as p95_ms by http_path
    | eval avg_ms=round(avg_ms,1), p95_ms=round(p95_ms,1)
    | sort -count
    ```

    Expected shape — `/actuator/health` dominates the count because kubelet probes it
    continuously:
    ```
    http_path          count avg_ms p95_ms
    /actuator/health   12720    1.8    4.3
    /                   2323    5.9   11.5
    /oups               2315    4.2    9.6
    /owners?lastName=   2255   16.6   32.4
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

**Check the Collector chart before bumping it.** The chart ships breaking changes on most
minor releases, and they are *silent* — the config renders, pods stay healthy, and no data
arrives. Before changing `OTEL_CHART_VERSION` in `versions.env`, render the overlay against
the new version and confirm the settings that have vanished in past releases are still
there:

```bash
source versions.env
helm repo add splunk-otel-collector-chart "$OTEL_CHART_REPO" && helm repo update
helm search repo splunk-otel-collector-chart/splunk-otel-collector -o json | jq -r '.[0].version'

export WS_USER=check LOCAL_IP=10.0.0.1 HEC_TOKEN=00000000-0000-0000-0000-000000000000
envsubst < labs/collector/values-workshop.yaml > /tmp/v.yaml
helm template t splunk-otel-collector-chart/splunk-otel-collector \
  --version <new-version> -f /tmp/v.yaml > /tmp/rendered.yaml

for k in splunk_hec docker_image_author 'recombine\|is_first_entry' k8s_objects; do
  grep -q "$k" /tmp/rendered.yaml || echo "MISSING: $k"
done
```

Each of those four has silently disappeared in a past chart release. A clean render is not
enough on its own — finish by running `verify-fw2.sh` against a live cluster, because that
is what proves data still arrives.

**Re-run the verification suite** against a fresh instance before each event. It takes
minutes and catches upstream drift that would otherwise surface mid-session.

**Version pins** all live in `versions.env`. Change them there and nowhere else.
