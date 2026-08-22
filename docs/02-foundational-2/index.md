# Foundational Workshop #2 — Collecting logs with OpenTelemetry

**Duration:** ~2 hours · **Prerequisite:** [FW #1](../01-foundational-1/index.md) complete
(`./scripts/verify-fw1.sh` passes)

In FW #1 you got an application running on Kubernetes. It's generating logs, the API server
is generating an audit trail — and none of it is going anywhere. In this module you'll
deploy the OpenTelemetry Collector and start capturing all of it into Splunk.

By the end you will have:

- [x] Splunk Enterprise running locally with indexes and an HTTP Event Collector endpoint
- [x] The Splunk OTel Collector deployed via Helm, shipping container and audit logs
- [x] Java stack traces arriving as single events instead of fragments
- [x] Pod metadata attached to events using annotations
- [x] Application logs routed to their own index
- [x] Log events reshaped in flight with an OTTL transform

Background reading: [The OpenTelemetry Collector and Helm](../concepts/otel-collector.md)

## Session variables

Every command below uses these. Load them into **each** terminal you use — including the
second one you'll open for load testing:

```bash
source ~/.workshop-env
echo "$WS_USER on $LOCAL_IP ($PUB_DNS)"
```

??? info "Missing, or starting from a fresh shell?"
    The file is created during [host setup](../00-setup/index.md). If it isn't there:

    ```bash
    cat > ~/.workshop-env <<'EOF'
    export WS_USER=<the username you were assigned, e.g. wsuser01>
    export LOCAL_IP=$(ec2metadata --local-ipv4)
    export PUB_DNS=$(ec2metadata --public-hostname)
    export CHART_VERSION=0.158.0
    export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
    EOF
    chmod 600 ~/.workshop-env
    source ~/.workshop-env
    ```

    Values added by later modules:

    | Variable | Set in | Used for |
    |---|---|---|
    | `HEC_TOKEN` | FW #2 step 3 | Collector → Splunk Enterprise |
    | `O11Y_REALM` | AW #2 step 1 | Observability Cloud realm, e.g. `us1` |

    Tokens themselves stay in files (`~/.o11y-token`, `~/.rum-token`) rather than in here,
    so they're never echoed to a terminal.


!!! note "`${WS_USER}` in YAML you edit by hand"
    Shell commands expand `${WS_USER}` for you. A **text editor does not** — typing it into
    a YAML file leaves the literal characters. Every "Full command sequence" below therefore
    includes a `sed` line that resolves it after you save:

    ```bash
    sed -i "s|\${WS_USER}|$WS_USER|g" <the-file>
    ```

    Run it, or just type your username directly instead of the placeholder. Either is fine —
    what matters is that no `${WS_USER}` survives into the deployed config.


---

## 1. Start Splunk Enterprise

```bash
sudo -i -u splunk
/opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt
/opt/splunk/bin/splunk status
```

Open Splunk Web and log in as `admin` with the password `Workshop2026!`:

```bash
echo "http://$PUB_DNS:8000"
```

![Splunk Enterprise login](../assets/img/02-fw2/image13.png)
<!-- STATUS: pending-recapture · 2023 · Splunk 10.4 login screen differs -->

---

## 2. Create the indexes

!!! abstract "Learning moment — why separate indexes"
    An index is Splunk's unit of **retention and access control**. Splitting data across
    indexes lets you keep infrastructure logs for 30 days and application logs for a year,
    or let the app team read their own logs without seeing cluster-wide audit data.

    You'll create five now and use them across this module and both Advanced workshops.

=== "Splunk Web"

    **Settings → Indexes → New Index**. Create these:

    | Index | Type |
    |---|---|
    | `k8s_ws_logs` | Events |
    | `k8s_ws_petclinic_logs` | Events |
    | `k8s_ws_traces` | Events |
    | `k8s_ws_metrics` | Metrics |
    | `k8s_ws_petclinic_metrics` | Metrics |

=== "Command line"

    ```bash
    SPLUNK=/opt/splunk/bin/splunk
    AUTH="-auth admin:Workshop2026!"

    for idx in k8s_ws_logs k8s_ws_petclinic_logs k8s_ws_traces; do
      $SPLUNK add index $idx $AUTH
    done

    for idx in k8s_ws_metrics k8s_ws_petclinic_metrics; do
      $SPLUNK add index $idx -datatype metric $AUTH
    done

    $SPLUNK list index $AUTH | grep k8s_ws
    ```

    !!! note "Every `/opt/splunk/bin/splunk` command prints a TLS warning"
        Each invocation emits `WARNING: Server Certificate Hostname Validation is disabled.
        Please see server.conf/[sslConfig]/cliVerifyServerName for details.` — once per
        command, here and everywhere else the CLI is used. It's expected on a lab instance
        with a self-signed certificate. Ignore it; it isn't a symptom of anything.

---

## 3. Create an HTTP Event Collector token

HEC is the HTTP endpoint the Collector will push events to.

!!! danger "Two toggles on the Global Settings page — you need to change both"
    On a clean Splunk 10.x install HEC ships **disabled**, and SSL ships **on**. Neither
    default is what this workshop needs, and changing only one of them still leaves you with
    a Collector that delivers nothing.

    **Settings → Data Inputs → HTTP Event Collector → Global Settings**:

    - Set **All Tokens** to **Enabled**. It ships **Disabled**, which means nothing is
      listening on 8088 at all — the smoke test below gets *connection refused*, not an
      authentication error.
    - Untick **Enable SSL**. This changed from earlier releases: in Splunk 10 HEC listens on
      **HTTPS** out of the box, so pointing the Collector at `http://…:8088` gets the
      connection reset, with **no useful error**.
    - Leave **HTTP Port Number** at `8088`, then **Save**.

=== "Splunk Web"

    **Settings → Data Inputs → HTTP Event Collector → New Token**

    - Name: `k8s-ws-hec`
    - Allowed indexes: all five you just created
    - Default index: `k8s_ws_logs`

    Copy the token value.

=== "Command line"

    Both halves of the step — the Global Settings change and the token — without needing a
    tunnel to port 8000.

    ```bash
    SPLUNK=/opt/splunk/bin/splunk
    AUTH="-auth admin:Workshop2026!"

    # Global Settings: enable HEC, turn SSL off, keep the port at 8088
    curl -sk -u admin:Workshop2026! -X POST \
      https://localhost:8089/servicesNS/nobody/splunk_httpinput/data/inputs/http/http \
      -d enableSSL=0 -d disabled=0 -d port=8088

    # New Token
    $SPLUNK http-event-collector create k8s-ws-hec -index k8s_ws_logs \
      -indexes k8s_ws_logs,k8s_ws_petclinic_logs,k8s_ws_traces,k8s_ws_metrics,k8s_ws_petclinic_metrics \
      -uri https://localhost:8089 $AUTH
    ```

    !!! warning "The subcommand is `http-event-collector`, and `-uri` is required"
        `splunk http create` — the shorter, more guessable form — **is not a valid command**
        on this Splunk version:
        ```
        Command error: 'http' is not a valid command.
        ```
        The real subcommand is `http-event-collector`, and unlike `add index` in step 2 it
        does not infer the management URI from context — omit `-uri https://localhost:8089`
        and it fails with `Splunk server uri is missing`, not an error you'd think to search
        for.

    The token value is printed in the output of the `http-event-collector create` command.
    As in step 2, each `$SPLUNK` call also prints the `Server Certificate Hostname
    Validation is disabled` warning — expected, ignore it.

Then confirm the whole path works before going further:

```bash
# Keep the token in the env file so you don't have to go looking for it again.
# Nothing sources this file for you — run `source ~/.workshop-env` in every new terminal.
echo 'export HEC_TOKEN=<your-token>' >> ~/.workshop-env
source ~/.workshop-env

curl -s -w '\n%{http_code}\n' "http://${LOCAL_IP}:8088/services/collector/event" \
  -H "Authorization: Splunk ${HEC_TOKEN}" \
  -H 'Content-Type: application/json' \
  --data-binary '{"event":"hec-smoketest","sourcetype":"workshop:test","index":"k8s_ws_logs"}'
```

### ✅ Checkpoint

You want `{"text":"Success","code":0}` and `200`.

<details>
<summary>If you get something else</summary>

| Response | Cause |
|---|---|
| Empty body, `000` | SSL still enabled on HEC — see the warning above |
| `{"text":"Invalid token"}` | Token copied incorrectly |
| `{"text":"Incorrect index"}` | Index not in the token's allowed list |
| Connection refused | **All Tokens** still `Disabled` in Global Settings, or Splunk not running |
</details>

Now find it in Splunk: `index=k8s_ws_logs hec-smoketest`

---

## 4. Deploy the OpenTelemetry Collector

!!! tip "We install from the chart repository, not a Git clone"
    Earlier versions of this workshop cloned the chart repo and edited its `values.yaml`
    in place. We use a small **overlay file** instead. It's a fraction of the size, it's
    the file you'd commit to Git in production, and — importantly — it survives a chart
    upgrade. Edits to a vendored `values.yaml` do not.

```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update
```

Create the overlay. This is the *entire* configuration:

```bash
mkdir -p ~/k8s_workshop/k8s_otel && cd ~/k8s_workshop/k8s_otel

cat > values-workshop.yaml <<EOF
clusterName: ${WS_USER}-minikube-cluster

splunkPlatform:
  endpoint: "http://${LOCAL_IP}:8088/services/collector"
  token: "${HEC_TOKEN}"
  index: "k8s_ws_logs"
  logsEnabled: true
  metricsEnabled: false
  tracesEnabled: false

logsCollection:
  containers:
    # Collect the Collector's own logs too — useful while learning.
    excludeAgentLogs: false

clusterReceiver:
  eventsEnabled: true
  k8sObjects:
    - name: pods
      mode: pull
      interval: 60s
    - name: events
      mode: watch
EOF
```

Preview what that produces *before* installing anything:

```bash
helm template t splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml | grep -A3 'splunk_hec/platform_logs'
```

Install it:

```bash
helm install ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml

kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent
kubectl get pods -o wide
```

!!! warning "Always pass `--version`"
    This chart is pre-1.0 and ships breaking changes on minor releases — roughly every two
    weeks. Without an explicit version you get whatever is current, and the workshop may
    behave differently from what's written here.

### ✅ Checkpoint

Two Collector pods `1/1 Running` — an **agent** DaemonSet (one per node, reads container
logs) and a **cluster receiver** Deployment (one per cluster, talks to the Kubernetes API).

Then search Splunk over the last 15 minutes:

```
index=k8s_ws_logs | stats count by sourcetype
```

<details>
<summary>Expected sourcetypes</summary>

```
kube:container:kube-apiserver                       5815
kube:container:storage-provisioner                   896
kube:container:otel-collector                         68
kube:container:${WS_USER}-petclinic-...               46
kube:object:pods                                      10
kube:container:etcd                                    9
workshop:test                                          1
```

**The counts are illustrative.** They vary a lot with how long the cluster has been up —
it's the rows that matter, not the numbers.

`kube:container:otel-collector` is the Collector reporting on itself, because the overlay
above set `excludeAgentLogs: false`. `workshop:test` is the single smoke-test event you sent
in step 3.

`kube:object:events` may be **missing entirely at this point, and that is not a fault**. It
is collected in `mode: watch`, so it only emits when something in the cluster *changes* — on
a quiet, freshly installed cluster there may be nothing for several minutes. Force one:

```bash
kubectl delete pod <any-pod>
```

No PetClinic rows yet? The application has had no traffic. That's what the load generator
in step 7 is for — for now, `curl http://minikube:30000/` a few times to prove the path
works.
</details>

---

## 5. Explore the Kubernetes audit log

This is the trail you enabled in FW #1, now searchable.

```
index=k8s_ws_logs sourcetype="kube:container:kube-apiserver"
```

Who has been talking to the API server anonymously, and what did they get back?

```
index=k8s_ws_logs sourcetype="kube:container:kube-apiserver" "user.username"="system:anonymous"
| rename sourceIPs{} as src_ip
| stats count min(_time) as firstTime max(_time) as lastTime
        values(responseStatus.reason) values(responseStatus.code)
        values(userAgent) values(verb) values(requestURI)
        by src_ip, "user.username", "k8s.cluster.name"
| eval firstTime=strftime(firstTime,"%c"), lastTime=strftime(lastTime,"%c")
```

!!! abstract "Learning moment — what this is worth"
    That single query is the basis of a whole family of Kubernetes detections: cluster
    scanning, service accounts hitting forbidden endpoints, access to sensitive objects.
    A set of ready-made searches ships in the [facilitator guide](../facilitator/index.md).

---

## 6. Make the application actually log

Before searching, there's a problem worth discovering yourself. Run some traffic, then look
at what the container emitted:

```bash
for i in $(seq 1 30); do curl -s -o /dev/null http://minikube:30000/; done
kubectl logs deploy/${WS_USER}-petclinic-otel-deployment --since=1m | wc -l
```

**Zero.** Thirty successful requests produced no log lines at all.

!!! tip "Do it in the browser too — it makes the point better"
    If your tunnel from [host setup](../00-setup/index.md) is still up, open
    **http://localhost:8080** and click around: find an owner, open their pet, add a visit.
    Otherwise reconnect with:

    ```bash
    ssh -i <your-key.pem> -L 8080:192.168.49.2:30000 splunk@<your-instance>
    ```

    Then re-run the `kubectl logs` line above. Still zero. Thirty automated requests are
    easy to dismiss; a few minutes of genuinely using an application and getting **not one
    line of output** is the thing worth remembering.

    No extra security-group rule is needed for this — the tunnel rides port 22.

!!! abstract "Learning moment — most applications are silent when healthy"
    Spring Boot logs at startup and when something throws. Successful requests produce
    nothing. That's normal and usually sensible — logging every request costs storage and
    tells you little that metrics don't.

    But it means an observability workshop built only on application logs would have almost
    nothing to look at, and it's why *access logs* exist as a separate concern: one line
    per request, recording what was asked for, what came back, and how long it took.

Enable Tomcat's access log, writing to stdout so the Collector picks it up like any other
container output. Add to the container's `env:` block in your manifest:

```yaml
        - name: SERVER_TOMCAT_ACCESSLOG_ENABLED
          value: "true"
        - name: SERVER_TOMCAT_ACCESSLOG_DIRECTORY
          value: "/dev"
        - name: SERVER_TOMCAT_ACCESSLOG_PREFIX
          value: "stdout"
        - name: SERVER_TOMCAT_ACCESSLOG_SUFFIX
          value: ""
        - name: SERVER_TOMCAT_ACCESSLOG_FILE_DATE_FORMAT
          value: ""
        - name: SERVER_TOMCAT_ACCESSLOG_BUFFERED
          value: "false"
        - name: SERVER_TOMCAT_ACCESSLOG_PATTERN
          value: '%h %l %u %t "%r" %s %b %D'
```

??? example "What your manifest should look like around here"
    Your manifest has **no `env:` key at all** at this point — FW #1's file doesn't create
    one, and nothing before this step has needed it. This is the first env entry in the
    whole workshop, so add `env:` as a new sibling of `ports:` inside the container spec,
    then the seven access-log variables under it as its first list items.

    The OTel telemetry variables (`SPLUNK_OTEL_AGENT`, `OTEL_EXPORTER_OTLP_ENDPOINT`) you'll
    see in the reference manifest at the bottom of this page don't exist yet — those are
    added in **AW #1**. The profiler variables and `LOGGING_PATTERN_LEVEL` come later still,
    in **AW #2**. Don't go looking for either now; access logging is genuinely alone here.

    ```yaml
          ports:
          - containerPort: 8080
          env:
          # --- FW2: access logging -----------------------------------------------
          # PetClinic logs nothing for successful requests — only startup and
          # exceptions. One line per request is what makes the log exercises work.
          # directory=/dev + prefix=stdout + empty suffix resolves to /dev/stdout.
          - name: SERVER_TOMCAT_ACCESSLOG_ENABLED
            value: "true"
          - name: SERVER_TOMCAT_ACCESSLOG_DIRECTORY
            value: "/dev"
          - name: SERVER_TOMCAT_ACCESSLOG_PREFIX
            value: "stdout"
          - name: SERVER_TOMCAT_ACCESSLOG_SUFFIX
            value: ""
          - name: SERVER_TOMCAT_ACCESSLOG_FILE_DATE_FORMAT
            value: ""
          - name: SERVER_TOMCAT_ACCESSLOG_BUFFERED
            value: "false"
          # Single quotes: the pattern contains double quotes.
          - name: SERVER_TOMCAT_ACCESSLOG_PATTERN
            value: '%h %l %u %t "%r" %s %b %D'
    ```

??? abstract "Full command sequence — manifest change (no image rebuild)"
    ```bash
    cd ~/k8s_workshop/petclinic/k8s_deploy
    ne ${WS_USER}-petclinic-k8s-manifest.yml     # or: vi

    # A text editor writes ${WS_USER} literally. Resolve it to your username:
    sed -i "s|\${WS_USER}|$WS_USER|g" ${WS_USER}-petclinic-k8s-manifest.yml

    kubectl apply -f ${WS_USER}-petclinic-k8s-manifest.yml
    kubectl rollout status deployment/${WS_USER}-petclinic-otel-deployment --timeout=300s

    # Confirm the pod picked it up
    kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- env | grep -E '^OTEL|^SPLUNK|^SERVER|^LOGGING'
    ```

    Environment and annotation changes do **not** need a new image — they live in the
    Deployment. Only changes inside the jar require a rebuild.

!!! tip "Why `/dev` + `stdout` + empty suffix"
    Tomcat builds its log filename from directory, prefix, date format and suffix. Setting
    them this way resolves to `/dev/stdout` — so access logs join the container's normal
    output instead of landing in a file nobody collects.

    Note the **single quotes** around the pattern: it contains double quotes, and YAML
    would otherwise need them escaped.

```bash
kubectl apply -f ~/k8s_workshop/petclinic/k8s_deploy/${WS_USER}-petclinic-k8s-manifest.yml
kubectl rollout status deployment/${WS_USER}-petclinic-otel-deployment
```

### ✅ Checkpoint

```bash
for i in $(seq 1 30); do curl -s -o /dev/null http://minikube:30000/; done
kubectl logs deploy/${WS_USER}-petclinic-otel-deployment --since=1m | tail -3
```

<details>
<summary>Expected — one line per request</summary>

```
10.244.0.1 - - [19/Aug/2026:21:26:38 +0000] "GET / HTTP/1.1" 200 3056 21630
10.244.0.1 - - [19/Aug/2026:21:26:38 +0000] "GET /owners?lastName= HTTP/1.1" 200 5015 72495
```

One line per request — thirty of them, against zero before. The trailing number is the
response time in microseconds, which becomes useful shortly.
</details>

---

## 7. Set up the load generator

You have one line per request now — but only for the requests you make by hand. Everything
from here on (multiline stack traces, annotations, transforms, and all of both Advanced
workshops) works far better with steady, repeatable traffic. So let's set up Apache JMeter
once and reuse it for the rest of the series.

!!! abstract "Learning moment — why generate load at all"
    Observability tooling only shows you what actually happened. With no traffic there are
    no application logs to transform, no error rates to read, and no traces to follow.

    The test plan below walks the PetClinic application the way a user would — find an
    owner, edit them, add a visit, browse vets — and deliberately triggers the app's error
    page on every pass, so you always have real exceptions to find.

### Open a second terminal

**JMeter runs in the foreground and won't give your prompt back.** You'll want one terminal
running load and another to keep working in.

```bash
ssh -i <your-key.pem> splunk@<your-instance>     # echo $PUB_DNS on the host for the name
```

!!! tip "If your session keeps timing out"
    Some hardened hosts log you out after ~15 minutes at an idle prompt, which will kill a
    running test. Use `tmux` so the run survives a disconnect:

    ```bash
    tmux new -s load          # start (or: tmux attach -t load to come back)
    ```

    Detach with ++ctrl+b++ then ++d++. The test keeps running.

### Install JMeter

```bash
source ~/.workshop-env                  # new terminal, so load the variables again
mkdir -p ~/k8s_workshop/jmeter && cd ~/k8s_workshop/jmeter

curl -fsSLO https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-5.6.3.tgz
tar -xzf apache-jmeter-5.6.3.tgz
rm apache-jmeter-5.6.3.tgz
./apache-jmeter-5.6.3/bin/jmeter --version
```

!!! note "Stock JMeter, no plugins"
    Earlier versions of this workshop used a custom 111 MB JMeter build. It isn't needed —
    this test plan uses only standard HTTP samplers. Advanced Workshop #2 handles
    browser-based testing separately, with Playwright.

### Get the test plan

```bash
curl -fsSLO https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop-2026/main/labs/jmeter/petclinic_test_plan.jmx
curl -fsSLO https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop-2026/main/labs/jmeter/petclinic_owner_pets.csv
ls -l
```

Both files must sit in the same directory — the plan reads the CSV by relative path.

??? info "What's in the CSV, and why it exists"
    PetClinic's seed data has 10 owners and 13 pets, and they are **not** numbered in
    parallel — owner 3 has two pets, so owner 4's pet is number 5, and it drifts from there:

    ```
    1→1   2→2   3→3,4   4→5   5→6   6→7,8   7→9   8→10   9→11   10→12,13
    ```

    An earlier version of this plan generated the two IDs with independent counters, which
    desynchronised after the third iteration and made ~90% of "add visit" requests fail
    with HTTP 500. The CSV supplies only real, verified pairs.

### Run it

```bash
./apache-jmeter-5.6.3/bin/jmeter -n \
  -t petclinic_test_plan.jmx \
  -JPETCLINIC_HOST=minikube \
  -JPETCLINIC_PORT=30000 \
  -l results.jtl
```

`-n` means non-GUI mode. 5 threads × 50 loops takes roughly **5 minutes**.

<details>
<summary>Expected output</summary>

```
summary =    971 in 00:01:06 = 14.8/s ... Err:  72 (7.42%)
summary =   1457 in 00:01:36 = 15.2/s ... Err: 110 (7.55%)
```

(The `Avg`/`Min`/`Max` columns are trimmed above for width; you'll see them.)

**The ~7.7% error rate is deliberate.** One sampler in thirteen calls the application's
`/oups` endpoint, which throws a `RuntimeException` on purpose. One in thirteen is **7.69%**,
which is the ceiling — early iterations run slightly under it, so a healthy run settles
somewhere around 7.4–7.7%. You'll go looking for those exceptions in a moment, and in the
Advanced workshops that same rate appears as the service error rate in APM.

Only worry if you're materially above **~10%** — then check that PetClinic is healthy with
`kubectl get pods`.
</details>

Stop early with ++ctrl+c++ if you need to. To run longer, raise the loop count:

```bash
./apache-jmeter-5.6.3/bin/jmeter -n -t petclinic_test_plan.jmx \
  -JPETCLINIC_HOST=minikube -JPETCLINIC_PORT=30000 \
  -Jloops=500 -l results.jtl
```

!!! tip "Leave it running"
    Switch back to your first terminal and carry on with the workshop while load continues.
    Every remaining step in this module benefits from live traffic. If the run finishes
    before you do, just start it again.

---

## 8. Find the error in Splunk

With load running, go to Splunk and search the last 15 minutes:

```
index=k8s_ws_logs "k8s.container.name"="${WS_USER}-petclinic-otel-container01" RuntimeException
```

You should see a steady stream of exceptions — the `/oups` endpoint firing on every pass of
the test plan.

!!! tip "Trigger one yourself and find it"
    JMeter's errors all look alike. Open **http://localhost:8080/oups** in the browser
    through your tunnel — you'll get PetClinic's error page — then note the time and search
    for that single exception. Following one failure you caused by hand, from click to
    stack trace, is a far better rehearsal for the Advanced workshops than reading a stream
    of identical machine-generated ones.

### ✅ Checkpoint — do the two systems agree?

JMeter reports roughly **7.7%** failures. Ask Splunk the same question — but ask it of the
*access log*, which is one line per request, exactly like JMeter's counter:

```
index=k8s_ws_logs "k8s.container.name"="${WS_USER}-petclinic-otel-container01"
| rex "\" (?<status>\d{3}) "
| where isnotnull(status)
| stats count(eval(status>=500)) as errors, count as requests
| eval error_pct = round(errors*100/requests, 2)
```

```
errors  requests  error_pct
    30       458       6.55
```

Within about a point of JMeter, over a shorter window. That's agreement. The same failures
are now visible in two places: the tool that *caused* them and the platform that *collected*
them. In the Advanced workshops a third view is added — APM's service error rate — and all
three land within a point of each other (measured over one window: JMeter 7.69%, Splunk
7.10%, APM 6.90%).

!!! abstract "Learning moment — what you count decides whether you agree"
    The obvious version of that query counts every event in the index:

    ```
    | stats count(eval(searchmatch("RuntimeException"))) as errors, count as total
    ```

    Run it and you get roughly **3.7%** against JMeter's 7.55%. Nothing is broken.

    `total` counts **log events, not requests**. At this point in the module a 100-line Java
    stack trace is 100 separate events, because nothing has reassembled it yet. Break the
    denominator down and it is 93% stack-trace continuation lines:

    ```
    stack-trace continuation  7821
    access-log line            451
    exception header           310
    other app log               60
    ```

    Neither side of that ratio corresponds to a request, so the percentage means nothing —
    and it drifts with stack depth, so you can't fix it by adjusting the expected number.

    Two systems appearing to disagree is far more often a difference in *what is being
    counted* than a sign that data was dropped. It is also the concrete reason for the next
    step: the denominator is polluted precisely because stack traces aren't reassembled yet.

Now look closely at **how** the exception arrived. The stack trace is **split across many
separate events**, one line each. That's the next problem to solve.

---

## 9. Reassemble stack traces with multiline configuration

!!! abstract "Learning moment — why this happens"
    A container log line is one JSON record per line of stdout. A 100-line Java stack trace
    is 100 separate records, and the Collector has no inherent way to know they belong
    together.

    You tell it: a **new** event starts at a line beginning with a non-whitespace character.
    Continuation lines are indented, so they get folded into the event above.

Add to `values-workshop.yaml`, under `logsCollection.containers`:

```yaml
logsCollection:
  containers:
    excludeAgentLogs: false
    multilineConfigs:
      - namespaceName:
          value: default
        podName:
          value: ${WS_USER}-petclinic-.*
          useRegexp: true
        containerName:
          value: ${WS_USER}-petclinic-otel-container01
        firstEntryRegex: ^[^\s].*
```

??? example "What your values file should look like around here"
    `multilineConfigs` is a sibling of `excludeAgentLogs`, both nested under `logsCollection.containers`.

    ```yaml
    # [FW2] Container log collection, plus multiline recombine.
    logsCollection:
      containers:
        excludeAgentLogs: false
        # FW2: recombine Java stack traces into a single event.
        # A new event starts at a line beginning with a non-whitespace char.
        multilineConfigs:
          - namespaceName:
              value: default
            podName:
              value: ${WS_USER}-petclinic-.*
              useRegexp: true
            containerName:
              value: ${WS_USER}-petclinic-otel-container01
            firstEntryRegex: ^[^\s].*
    ```

??? abstract "Full command sequence — collector change"
    ```bash
    cd ~/k8s_workshop/k8s_otel
    ne values-workshop.yaml          # or: vi values-workshop.yaml

    # A text editor writes ${WS_USER} literally. Resolve it to your username:
    sed -i "s|\${WS_USER}|$WS_USER|g" values-workshop.yaml
    grep -n "$WS_USER" values-workshop.yaml | head    # confirm

    # Validate first. The chart schema is the only check in this workshop that
    # fails loudly instead of silently doing nothing.
    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml --dry-run=client

    # Apply
    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml

    kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent --timeout=300s

    # Confirm the change actually reached the running config
    kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
      -o go-template='{{index .data "relay"}}' | grep -A5 'transform/'
    ```

```bash
helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent
```

If your JMeter run has finished, start it again in your second terminal — you need live
traffic for the next search. Then:

```
index=k8s_ws_logs RuntimeException
| eval lines=mvcount(split(_raw,"
")) | stats count by lines
```

### ✅ Checkpoint

Events with ~100 lines instead of dozens of 1-line events. The full trace is now one
searchable record.

---

## 10. Attach pod metadata with annotations

!!! abstract "Learning moment — annotations vs labels
    **Labels** are for *selection* — Kubernetes uses them to find objects. **Annotations**
    are for *metadata* — arbitrary information attached to an object for tools to read.

    The Collector can promote annotations onto every event from that pod, which is how you
    tag telemetry with ownership, cost centre, or application version without touching
    application code.

Add annotations to the pod template in your manifest:

```yaml
  template:
    metadata:
      labels:
        app: ${WS_USER}-petclinic-otel-app
      annotations:
        docker_image_author: "${WS_USER}"
        splunk.com/index: "k8s_ws_petclinic_logs"
```

??? example "What your manifest should look like around here"
    Annotations go on the **pod template** (`spec.template.metadata`), not on the Deployment's own metadata. This is the single most common mistake in this step.

    ```yaml
        matchLabels:
          app: ${WS_USER}-petclinic-otel-app
      template:
        metadata:
          labels:
            app: ${WS_USER}-petclinic-otel-app
          annotations:
            docker_image_author: "${WS_USER}"
            splunk.com/index: "k8s_ws_petclinic_logs"
    ```

??? abstract "Full command sequence — manifest change (no image rebuild)"
    ```bash
    cd ~/k8s_workshop/petclinic/k8s_deploy
    ne ${WS_USER}-petclinic-k8s-manifest.yml     # or: vi

    # A text editor writes ${WS_USER} literally. Resolve it to your username:
    sed -i "s|\${WS_USER}|$WS_USER|g" ${WS_USER}-petclinic-k8s-manifest.yml

    kubectl apply -f ${WS_USER}-petclinic-k8s-manifest.yml
    kubectl rollout status deployment/${WS_USER}-petclinic-otel-deployment --timeout=300s

    # Confirm the pod picked it up
    kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- env | grep -E '^OTEL|^SPLUNK|^SERVER|^LOGGING'
    ```

    Environment and annotation changes do **not** need a new image — they live in the
    Deployment. Only changes inside the jar require a rebuild.

Tell the Collector to pick that annotation up — add to `values-workshop.yaml`:

```yaml
extraAttributes:
  fromAnnotations:
    - key: docker_image_author
      from: pod
      tag_name: docker_image_author
```

!!! tip "`tag_name` gives you a clean field name"
    Without it the attribute arrives as `k8s.pod.annotations.docker_image_author`.
    `tag_name` sets the final name directly, so no post-processing is needed to strip the
    prefix.

Apply both:

```bash
kubectl apply -f ~/k8s_workshop/petclinic/k8s_deploy/${WS_USER}-petclinic-k8s-manifest.yml
helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
kubectl rollout status deployment/${WS_USER}-petclinic-otel-deployment
```

### ✅ Checkpoint — two things changed at once

```
| tstats count where index=k8s_ws_logs OR index=k8s_ws_petclinic_logs by index
index=k8s_ws_petclinic_logs | stats count by docker_image_author
```

The `splunk.com/index` annotation **rerouted PetClinic logs to their own index**, and
`docker_image_author` is now a field on every one of those events.

---

## 11. Reshape events in flight with OTTL

!!! abstract "Learning moment — transform before it lands
    Splunk can rewrite data at index time, but doing it in the Collector means it happens
    once, close to the source, and applies no matter which backend the data goes to. The
    language is **OTTL** — the OpenTelemetry Transformation Language.

Add to `values-workshop.yaml`:

```yaml
agent:
  config:
    processors:
      transform/petclinic_logs:
        log_statements:
          - set(resource.attributes["com.splunk.sourcetype"], "petclinic:app:log")
              where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
          - merge_maps(log.attributes,
              ExtractPatterns(log.body, "(?P<log_level>INFO|WARN|ERROR|DEBUG|TRACE)"),
              "upsert")
              where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
          # Severity: set the RECORD's severity_text, not an attribute.
          - set(log.severity_text, log.attributes["log_level"])
              where log.attributes["log_level"] != nil
          - set(log.severity_number, SEVERITY_NUMBER_ERROR) where log.attributes["log_level"] == "ERROR"
          - set(log.severity_number, SEVERITY_NUMBER_WARN)  where log.attributes["log_level"] == "WARN"
          - set(log.severity_number, SEVERITY_NUMBER_INFO)  where log.attributes["log_level"] == "INFO"
          - set(log.severity_number, SEVERITY_NUMBER_DEBUG) where log.attributes["log_level"] == "DEBUG"

          # A recombined stack trace begins with the exception class and carries
          # no level token of its own, so classify it explicitly.
          - set(log.severity_text, "ERROR")
              where log.attributes["log_level"] == nil and IsMatch(log.body, "Exception")
          - set(log.severity_number, SEVERITY_NUMBER_ERROR) where log.severity_text == "ERROR"

          # Access logs carry no level token either. Parse them into fields, then
          # derive a severity from the HTTP status — a 5xx is an error even though
          # the line never says so.
          - merge_maps(log.attributes,
              ExtractPatterns(log.body,
                "^\\S+ \\S+ \\S+ \\[[^\\]]+\\] \"(?P<http_method>[A-Z]+) (?P<http_path>\\S+)[^\"]*\" (?P<http_status>\\d{3}) (?P<http_bytes>\\S+) (?P<http_duration_us>\\d+)"),
              "upsert")
              where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
          - set(log.severity_text, "INFO")  where log.attributes["http_status"] != nil
          - set(log.severity_text, "WARN")  where IsMatch(log.attributes["http_status"], "^4")
          - set(log.severity_text, "ERROR") where IsMatch(log.attributes["http_status"], "^5")
          - set(log.severity_number, SEVERITY_NUMBER_INFO) where log.severity_text == "INFO"
          - set(log.severity_number, SEVERITY_NUMBER_WARN) where log.severity_text == "WARN"

          # Log Observer's Severity column reads the RECORD's severity_text — which the
          # splunk_hec exporter writes to Splunk as `otel.log.severity.text`, not as
          # something you'd think to search on. Mirror it to an attribute so the same
          # value is also a plain `severity` field in Splunk. One source of truth, two
          # consumers. Leave this out and every `severity` search in this module, and in
          # AW #2, returns nothing.
          - set(log.attributes["severity"], log.severity_text) where log.severity_text != nil
    service:
      pipelines:
        logs:
          processors:
            - memory_limiter
            - k8s_attributes
            - filter/logs
            - transform/petclinic_logs
            - batch
            - resource_detection
            - resource
            - resource/logs
```

??? abstract "Full command sequence — collector change"
    ```bash
    cd ~/k8s_workshop/k8s_otel
    ne values-workshop.yaml          # or: vi values-workshop.yaml

    # A text editor writes ${WS_USER} literally. Resolve it to your username:
    sed -i "s|\${WS_USER}|$WS_USER|g" values-workshop.yaml
    grep -n "$WS_USER" values-workshop.yaml | head    # confirm

    # Validate first. The chart schema is the only check in this workshop that
    # fails loudly instead of silently doing nothing.
    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml --dry-run=client

    # Apply
    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml

    kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent --timeout=300s

    # Confirm the change actually reached the running config
    kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
      -o go-template='{{index .data "relay"}}' | grep -A5 'transform/'
    ```

!!! danger "Three things here bite people — read before you debug"
    **1. Paths must be context-prefixed.** Write `log.attributes[...]` and
    `resource.attributes[...]`, not bare `attributes[...]`. Older syntax using
    `context: log` with bare paths **parses, deploys, and silently does nothing.**

    **2. Know which context an attribute lives in.** `com.splunk.sourcetype` and everything
    under `k8s.*` are **resource** attributes. Fields you extract from the log body are
    **log record** attributes. Target the wrong one and your `where` clause never matches.

    **3. Severity is a record field, not an attribute.** Setting
    `log.attributes["severity"]` produces a searchable field in Splunk but leaves
    Observability Cloud's Severity column showing **UNKNOWN**. Only `log.severity_text`
    and `log.severity_number` drive it. That's why the last statement in the block sets
    **both**: the record field for Log Observer, the mirrored attribute for Splunk search.

    There is no error for any of these. The Collector stays healthy and no data changes.

!!! warning "`severity_text` is empty, not nil"
    A tempting fallback is `where log.severity_text == nil`. It never matches — an unset
    `severity_text` is an **empty string**. Test the thing you actually extracted
    (`log.attributes["log_level"] == nil`) instead. This one cost real debugging time.

```bash
helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent
```

### ✅ Checkpoint

Three searches. The sourcetype should have been rewritten, severity should be derived from
the HTTP status, and response times should now be measurable straight from the logs:

```
index=k8s_ws_petclinic_logs | stats count by sourcetype
```

```
index=k8s_ws_petclinic_logs | stats count by http_status, severity
```

```
index=k8s_ws_petclinic_logs http_duration_us=*
| eval ms=http_duration_us/1000
| stats count, avg(ms) as avg_ms by http_path
| eval avg_ms=round(avg_ms,1)
| sort -count
```

!!! note "`round()` goes after `stats`, not inside it"
    Writing `| stats count, round(avg(ms),1) as avg_ms by http_path` looks reasonable and is
    rejected: *`Error in 'stats' command: The argument 'round(avg(ms),1)' is invalid`*.
    `stats` takes aggregates, not eval functions wrapping aggregates — round afterwards, in
    its own `eval`. In Splunk Web this arrives as a red banner over an empty results pane,
    which reads like "no data" rather than "bad query".

<details>
<summary>Expected</summary>

Second search — severity derived from the status code:

```
http_status  severity  count
200          INFO       2438
302          INFO        200
500          ERROR       221
```

Third search — response times per endpoint:

```
http_path                                          count  avg_ms
/                                                    240     3.0
/resources/css/petclinic.css                         240     3.1
/webjars/bootstrap/dist/js/bootstrap.bundle.min.js   239     1.9
/owners/find                                         238     4.1
/owners?lastName=                                    238    10.0
/vets.html                                           238     5.0
```

Counts are illustrative, but their *shape* isn't: every non-`/oups` sampler fires once per
iteration, so the top rows sit within one or two of each other. Neither of these searches was
possible before access logging.

Second search came back **empty**? `stats by` on a field that does not exist returns zero
rows rather than an error, so an empty table means `severity` was never created — not that
your `where` clauses failed to match. Check the mirror statement
(`set(log.attributes["severity"], log.severity_text)`) is present in your transform.

Still seeing `kube:container:...`? The transform didn't apply. Read the *generated* config
— this is the debugging move that resolves it:

```bash
kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
  -o go-template='{{index .data "relay"}}' | grep -A15 'transform/petclinic'
```
</details>

---

## 12. Install the workshop dashboard app

Every capstone dashboard in this series ships as one Splunk app, installed once, here.
You will not download a dashboard again — AW #1 and AW #2 just point you at the ones you
already have.

```bash
cd ~/k8s_workshop
curl -fsSLO https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop-2026/main/labs/dashboards/dist/k8s-ws-dashboards-1.0.1.tgz
sudo -i -u splunk /opt/splunk/bin/splunk install app \
  "$PWD/k8s-ws-dashboards-1.0.1.tgz" -auth admin:Workshop2026!
```

!!! success "No restart needed"
    The app contains only dashboards, so Splunk picks them up immediately — this was tested,
    not assumed: install, then open a dashboard, with no restart in between. If you have
    installed Splunk apps before and are expecting a restart prompt, you are not missing a
    step — there isn't one.

    The command prints a TLS warning about certificate hostname validation before the
    success line. That is unrelated boilerplate about the CLI talking to the management
    port, and it appears on this instance for every `splunk` CLI call.

The dashboards appear two ways, and both work:

- **K8s + OTel Workshop** — a new app in the app menu, with the dashboards ordered by module
- **Search & Reporting → Dashboards** — where you have been working all along

That second one is not an accident. The app exports its views to the system, which is also
the fix for a subtler problem: a dashboard pasted into the UI by hand lands in *your private
namespace* and is invisible to every other user on the instance. An app shares it properly.

??? abstract "What's in the app, and what deliberately isn't"
    Five dashboards:

    | Dashboard | Filled in by |
    |---|---|
    | Foundational Workshop 2 — What You Built | this module |
    | Advanced Workshop #1 — Metrics & Traces | AW #1 |
    | Advanced Workshop #1 — Infrastructure & Collector Health | AW #1 |
    | Advanced Workshop #2 — Correlation | AW #2 |
    | Application Trace Information v4.0.0 | AW #1 |

    The four you have not earned yet will open to empty panels. That is expected — treat
    them as a preview of what you are about to build. The three AW dashboards say so in an
    orange banner at the top; *Application Trace Information v4.0.0* does not, because it is
    kept byte-for-byte as released, and it also needs you to pick a trace index by hand
    before it shows anything.

    The app carries **dashboards and nav only**. It does not create your indexes, your HEC
    token, or the OTTL transform from §11 — you built those by hand in this module on
    purpose, and shipping them in an app would have deleted the lesson.

??? abstract "Alternative — install from the Splunk Web UI"
    If you would rather not use the CLI: **Apps ⚙ → Manage Apps → Install app from file**,
    choose the `.tgz`, and upload. The web installer may offer a restart; you can decline it.

### The dashboard for this module

Open **Foundational Workshop 2 — What You Built**.

![FW2 dashboard](../assets/img/02-fw2/fw2-dashboard.png)

The first half is the proof of your own pipeline, all backed by queries verified against
live workshop data: Total Requests, Error Rate %, Distinct Routes, a request-volume
timechart splitting 5xx from everything else, the severity/status breakdown that proves
§11's OTTL transform, a live feed of the most recent `RuntimeException` stack traces — now
single events instead of the scattered lines §9 fixed — and the index-routing proof from
§10: one log stream, split in two.

The second half asks what all this data is actually *worth*. The same Collector that ships
your application logs is also shipping the `kube-apiserver` audit stream — a record of every
call made to your cluster's control plane. Five panels read it: who is talking to the
Kubernetes API and with which verbs, how much unauthenticated (anonymous) access there is
and what it is hitting, the verb-against-resource mix, a write-operations audit trail of who
changed what and when, and access to sensitive resources — secrets, service accounts and
RBAC objects.

No application log can answer "who deleted that deployment?" or "is anything
unauthenticated talking to my API server?" These panels can. On this lab cluster the answers
are reassuringly boring — that is exactly the point: these are the queries whose answers
matter in production, and you now have the pipeline that feeds them.

!!! note "Distinct Routes counts routes, not URLs"
    That panel strips `;jsessionid=…` path parameters and numeric IDs before counting. Left
    raw, every session and every owner ID becomes its own "route" and the number runs into
    the thousands — on a 30-minute window this lab reports about 12 real routes against
    roughly 2,000 raw paths. Worth recognising: it is the same high-cardinality trap that
    inflates metric cardinality, and metric cardinality is what you get billed on.

---

## Reference — complete files at the end of this module

If something isn't behaving, compare your files against these rather than re-reading the
steps. They're the exact files this module was tested with.


??? example "values-workshop.yaml (collector overlay)"
    This is the **final** state of the file, after AW #1 and AW #2. Each top-level
    section is tagged `[FW2]`, `[AW1]` or `[AW2]` with the module that introduces it —
    at the end of FW #2 you have the `[FW2]` sections only, and the rest is here so the
    whole series has one canonical file to compare against. Placeholders are rendered
    with `envsubst`; substitute your own values by hand if you prefer.
    ```yaml
    # Splunk OTel Collector — final workshop overlay (FW2 + AW1 + AW2).
    # TESTED end to end on 2026-08-19 against chart 0.158.0.
    #
    # Render:  WS_USER=<you> LOCAL_IP=$(ec2metadata --local-ipv4) \
    #          HEC_TOKEN=<hec> \
    #          envsubst < values-final.yaml > my-values.yaml
    #
    # The Observability Cloud ingest token is NOT rendered into the file. It is
    # passed at install time, straight out of ~/.o11y-token:
    # Install: helm upgrade <you>-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
    #            --version 0.158.0 -f my-values.yaml \
    #            --set splunkObservability.accessToken="$(cat ~/.o11y-token)"
    #
    # Validate first — the chart schema is the only check that fails loudly:
    #          helm upgrade ... --dry-run=client
    # [FW2] Identifies this cluster on every metric, trace and log.
    clusterName: ${WS_USER}-minikube-cluster

    # [AW2] Second destination. Added without changing how anything is collected.
    splunkObservability:
      realm: "us1"
      # accessToken is deliberately absent. It is supplied at install time with
      #   --set splunkObservability.accessToken="$(cat ~/.o11y-token)"
      # so the ingest token never lands in a file that gets compared, pasted or
      # published — which is what makes this reference file safe to share.
      metricsEnabled: true
      tracesEnabled: true
      profilingEnabled: true     # enabled in step 6

    # [FW2] Splunk Enterprise via HEC.  [AW1] adds metricsIndex / tracesIndex.
    splunkPlatform:
      endpoint: "http://${LOCAL_IP}:8088/services/collector"
      token: "${HEC_TOKEN}"
      index: "k8s_ws_logs"
      metricsIndex: "k8s_ws_metrics"
      tracesIndex: "k8s_ws_traces"
      logsEnabled: true
      metricsEnabled: true
      tracesEnabled: true

    # [FW2] Container log collection, plus multiline recombine.
    logsCollection:
      containers:
        excludeAgentLogs: false
        # FW2: recombine Java stack traces into a single event.
        # A new event starts at a line beginning with a non-whitespace char.
        multilineConfigs:
          - namespaceName:
              value: default
            podName:
              value: ${WS_USER}-petclinic-.*
              useRegexp: true
            containerName:
              value: ${WS_USER}-petclinic-otel-container01
            firstEntryRegex: ^[^\s].*

    # FW2: promote pod annotations to event attributes.
    # tag_name gives a clean field name directly — no regex prefix-stripping needed.
    # [FW2] Promote pod annotations onto events.
    extraAttributes:
      fromAnnotations:
        - key: docker_image_author
          from: pod
          tag_name: docker_image_author

    # [FW2] Cluster-level objects and events.
    clusterReceiver:
      eventsEnabled: true
      k8sObjects:
        - name: pods
          mode: pull
          interval: 60s
        - name: events
          mode: watch

    # FW2: OTTL transform.
    # NOTE: modern OTTL requires context-prefixed paths (log.* / resource.*).
    # sourcetype and k8s.* are RESOURCE attributes, not log-record attributes.
    # [FW2] OTTL transforms.  [AW1] metric/trace index routing.
    # [AW2] service.name + deployment.environment for Related Content.
    agent:
      config:
        processors:
          # There is no splunk.com/tracesIndex annotation, so traces inherit
          # splunk.com/index from the pod. Override it for traces only.
          # Route this application's metrics to their own index, keyed on the
          # service name the Java agent reports. Same mechanism as traces.
          transform/app_metrics_index:
            metric_statements:
              - set(resource.attributes["com.splunk.index"], "k8s_ws_petclinic_metrics")
                  where resource.attributes["service.name"] == "${WS_USER}-k8s-petclinic-service"
          transform/traces_index:
            trace_statements:
              - set(resource.attributes["com.splunk.index"], "k8s_ws_traces")
          transform/petclinic_logs:
            log_statements:
              - set(resource.attributes["com.splunk.sourcetype"], "petclinic:app:log")
                  where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"

              # Related Content correlates on host.name, service.name and trace_id.
              # host.name arrives from resource detection; trace_id is printed by the
              # app and auto-extracted by Splunk. service.name has to be set here.
              - set(resource.attributes["service.name"], "${WS_USER}-k8s-petclinic-service")
                  where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
              - set(resource.attributes["deployment.environment"], "${WS_USER}-k8s-petclinic-env")
                  where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"

              - merge_maps(log.attributes,
                  ExtractPatterns(log.body, "(?P<log_level>INFO|WARN|ERROR|DEBUG|TRACE)"),
                  "upsert")
                  where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"

              # Log Observer's Severity column reads the record's severity_text, NOT a
              # custom attribute. An attribute named "severity" leaves it UNKNOWN.
              - set(log.severity_text, log.attributes["log_level"])
                  where log.attributes["log_level"] != nil
              - set(log.severity_number, SEVERITY_NUMBER_ERROR) where log.attributes["log_level"] == "ERROR"
              - set(log.severity_number, SEVERITY_NUMBER_WARN)  where log.attributes["log_level"] == "WARN"
              - set(log.severity_number, SEVERITY_NUMBER_INFO)  where log.attributes["log_level"] == "INFO"
              - set(log.severity_number, SEVERITY_NUMBER_DEBUG) where log.attributes["log_level"] == "DEBUG"

              # A recombined stack trace starts with the exception class and carries no
              # level token, so classify it explicitly.
              - set(log.severity_text, "ERROR")
                  where log.attributes["log_level"] == nil and IsMatch(log.body, "Exception")
              - set(log.severity_number, SEVERITY_NUMBER_ERROR) where log.severity_text == "ERROR"

              # Tomcat access logs carry no level token. Parse them, then derive a
              # severity from the HTTP status — 5xx is an error even though the line
              # never says so.
              - merge_maps(log.attributes,
                  ExtractPatterns(log.body,
                    "^\\S+ \\S+ \\S+ \\[[^\\]]+\\] \"(?P<http_method>[A-Z]+) (?P<http_path>\\S+)[^\"]*\" (?P<http_status>\\d{3}) (?P<http_bytes>\\S+) (?P<http_duration_us>\\d+)"),
                  "upsert")
                  where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
              - set(log.severity_text, "INFO")  where log.attributes["http_status"] != nil
              - set(log.severity_text, "WARN")  where IsMatch(log.attributes["http_status"], "^4")
              - set(log.severity_text, "ERROR") where IsMatch(log.attributes["http_status"], "^5")
              - set(log.severity_number, SEVERITY_NUMBER_INFO)  where log.severity_text == "INFO"
              - set(log.severity_number, SEVERITY_NUMBER_WARN)  where log.severity_text == "WARN"

              # Mirror to an attribute so the value is searchable as a field too.
              - set(log.attributes["severity"], log.severity_text) where log.severity_text != nil
        service:
          pipelines:
            metrics:
              processors:
                - memory_limiter
                - k8s_attributes
                - transform/app_metrics_index
                - batch
                - resource_detection
                - resource
            traces:
              processors:
                - memory_limiter
                - k8s_attributes
                - transform/traces_index
                - batch
                - resource_detection
                - resource
            logs:
              processors:
                - memory_limiter
                - k8s_attributes
                - filter/logs
                - transform/petclinic_logs
                - batch
                - resource_detection
                - resource
                - resource/logs
    ```

??? example "petclinic manifest"
    Also the **final** state: the profiler variables and `LOGGING_PATTERN_LEVEL` below
    are added in AW #2, so at the end of FW #2 your manifest is this file minus those
    three blocks. The comments name the module each one belongs to.

    ```yaml
    # PetClinic Deployment + NodePort Service — final workshop state.
    # TESTED 2026-08-19. Render with: WS_USER=<you> envsubst < petclinic-final.yml
    apiVersion: v1
    kind: Service
    metadata:
      name: ${WS_USER}-petclinic-srv
    spec:
      type: NodePort
      selector:
        app: ${WS_USER}-petclinic-otel-app
      ports:
      - protocol: TCP
        port: 8080
        targetPort: 8080
        nodePort: 30000
    ---
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: ${WS_USER}-petclinic-otel-deployment
      labels:
        app: ${WS_USER}-petclinic-otel-app
    spec:
      selector:
        matchLabels:
          app: ${WS_USER}-petclinic-otel-app
      template:
        metadata:
          labels:
            app: ${WS_USER}-petclinic-otel-app
          annotations:
            docker_image_author: "${WS_USER}"
            splunk.com/index: "k8s_ws_petclinic_logs"
        spec:
          containers:
          - name: ${WS_USER}-petclinic-otel-container01
            image: ${WS_USER}/petclinic-otel:v1
            imagePullPolicy: Never
            ports:
            - containerPort: 8080
            env:
            # --- AW1: where to send telemetry -------------------------------------
            # The collector agent is a DaemonSet, so the right target is whichever
            # node this pod landed on. A pod cannot resolve the `minikube` hosts
            # entry — that exists only on the host.
            - name: SPLUNK_OTEL_AGENT
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://$(SPLUNK_OTEL_AGENT):4317"

            # --- AW2: AlwaysOn Profiling ------------------------------------------
            - name: SPLUNK_PROFILER_ENABLED
              value: "true"
            - name: SPLUNK_PROFILER_MEMORY_ENABLED
              value: "true"
            # Defaults to http/protobuf on :4318, but our endpoint above is gRPC on
            # :4317. Mismatched, the profiler starts and sends nothing, with no error.
            - name: SPLUNK_PROFILER_OTLP_PROTOCOL
              value: "grpc"

            # --- AW2: trace context in the log line --------------------------------
            # The agent already puts trace_id/span_id in the MDC; Spring Boot's
            # default pattern just never prints them. Without this there is no
            # trace_id on the logs and APM <-> Logs correlation cannot work.
            - name: LOGGING_PATTERN_LEVEL
              value: "%5p [trace_id=%X{trace_id:-} span_id=%X{span_id:-}]"

            # --- FW2: access logging -----------------------------------------------
            # PetClinic logs nothing for successful requests — only startup and
            # exceptions. One line per request is what makes the log exercises work.
            # directory=/dev + prefix=stdout + empty suffix resolves to /dev/stdout.
            - name: SERVER_TOMCAT_ACCESSLOG_ENABLED
              value: "true"
            - name: SERVER_TOMCAT_ACCESSLOG_DIRECTORY
              value: "/dev"
            - name: SERVER_TOMCAT_ACCESSLOG_PREFIX
              value: "stdout"
            - name: SERVER_TOMCAT_ACCESSLOG_SUFFIX
              value: ""
            - name: SERVER_TOMCAT_ACCESSLOG_FILE_DATE_FORMAT
              value: ""
            - name: SERVER_TOMCAT_ACCESSLOG_BUFFERED
              value: "false"
            # Single quotes: the pattern contains double quotes.
            - name: SERVER_TOMCAT_ACCESSLOG_PATTERN
              value: '%h %l %u %t "%r" %s %b %D'
            readinessProbe:
              httpGet:
                path: /actuator/health
                port: 8080
              initialDelaySeconds: 10
              periodSeconds: 5
              failureThreshold: 30
    ```

!!! tip "Diff instead of re-reading"
    ```bash
    curl -fsSL -o /tmp/reference.yaml \
      https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop-2026/main/labs/collector/values-final.yaml
    diff <(sed 's/[[:space:]]*$//' ~/k8s_workshop/k8s_otel/values-workshop.yaml) \
         <(sed 's/[[:space:]]*$//' /tmp/reference.yaml)
    ```
    Same file as the block above, so expect the `[AW1]` and `[AW2]` sections to show as
    differences — ignore anything tagged for a module you haven't reached yet.

## ✅ Module checkpoint

```bash
~/k8s-otel-workshop/scripts/verify-fw2.sh
```

The script logs into Splunk to run its searches. It defaults to `admin:Workshop2026!` — the
credentials this workshop uses. If you changed the admin password during host setup, tell it
so first:

```bash
export SPLUNK_AUTH=admin:<your-admin-password>
~/k8s-otel-workshop/scripts/verify-fw2.sh
```

---

## Troubleshooting

??? failure "No data at all in `k8s_ws_logs`"
    Work outward from Splunk. First confirm HEC directly with the `curl` from step 3 — if
    that fails, it's Splunk-side (SSL, token, index permissions), not the Collector. If it
    succeeds, check the Collector's export errors:
    ```bash
    kubectl logs daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent | grep -i error
    ```

??? failure "`received a 410 ... resourceVersion is too old`"
    **Normal.** The cluster receiver re-establishes its watch against the Kubernetes API
    periodically and logs this at INFO. Not an error, no action needed.

??? failure "A configuration change appears to do nothing"
    The most common failure in this module, and it's always silent. Read the generated
    config and confirm your change is actually present:
    ```bash
    kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
      -o go-template='{{index .data "relay"}}'
    ```
    If it isn't there, the overlay didn't apply — check indentation and re-run
    `helm upgrade`. If it *is* there but has no effect, the condition isn't matching:
    re-read the OTTL warning in step 11.

??? failure "PetClinic logs still going to `k8s_ws_logs`"
    Annotations live on the **pod template** (`spec.template.metadata.annotations`), not on
    the Deployment's own metadata. Confirm what the running pod actually has:
    ```bash
    kubectl get pods -l app=${WS_USER}-petclinic-otel-app -o jsonpath='{.items[*].metadata.annotations}'
    ```

---

**Next:** [Advanced Workshop #1 — Metrics and traces](../03-advanced-1/index.md)
