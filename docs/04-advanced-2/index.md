# Advanced Workshop #2 — Splunk Observability Cloud

**Duration:** ~2 hours · **Prerequisite:** [AW #1](../03-advanced-1/index.md) complete
(`./scripts/verify-aw1.sh` passes)

Everything so far has gone to Splunk Enterprise. This module adds Splunk Observability
Cloud as a **second destination** — without changing how anything is collected — and then
uses it to follow a problem from a service, to the infrastructure under it, to the log line
that explains it.

By the end you will have:

- [x] Infrastructure and APM data in Observability Cloud
- [x] Log Observer Connect querying your Splunk Enterprise indexes
- [x] AlwaysOn Profiling showing where the JVM spends its time
- [x] Real User Monitoring capturing actual browser sessions
- [x] Walked APM → Infrastructure → Logs on a single problem

Background: [Why observability](../concepts/observability.md)

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
    export WS_USER=<your-username>
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

## 1. Get an access token

You need an Observability Cloud organisation. A 14-day trial is enough for the whole
module.

In Observability Cloud: **Settings → Access Tokens → New Token**, scope **INGEST**.
Note your **realm** too — it's in the URL (`app.us1.signalfx.com` → realm `us1`).

!!! warning "Treat this as a credential"
    An ingest token can write data into your organisation. Don't paste it into a shared
    document or commit it. For the workshop, keep it in a file outside any Git repository:

    ```bash
    umask 077
    printf '%s' '<YOUR_TOKEN>' > ~/.o11y-token
    ```

    `printf` rather than `echo` — a trailing newline in a token causes authentication
    failures that are genuinely unpleasant to diagnose.

Confirm the token works before configuring anything:

```bash
echo 'export O11Y_REALM=us1' >> ~/.workshop-env      # your realm
source ~/.workshop-env

curl -s -o /dev/null -w '%{http_code}\n' \
  -H "X-SF-Token: $(cat ~/.o11y-token)" -H 'Content-Type: application/json' \
  -d '[{"gauge":[{"metric":"workshop.preflight","value":1}]}]' \
  "https://ingest.${O11Y_REALM}.signalfx.com/v2/datapoint"
```

`200` means the token and realm are both right. `401` means one of them isn't.

---

## 2. Add Observability Cloud to the Collector

!!! abstract "Learning moment — one collector, two destinations"
    This is the payoff for using OpenTelemetry. You are about to send metrics and traces to
    an entirely different platform **without touching the application, the instrumentation,
    or how anything is collected.** You add a destination.

    That is the vendor-neutrality argument in practice rather than in principle.

Add to `~/k8s_workshop/k8s_otel/values-workshop.yaml`, above `splunkPlatform`:

```yaml
splunkObservability:
  realm: "us1"          # must match $O11Y_REALM
  accessToken: "<YOUR_INGEST_TOKEN>"
  metricsEnabled: true
  tracesEnabled: true
  profilingEnabled: false      # switched on in step 6
```

??? example "What your values file should look like around here"
    `splunkObservability` is a new top-level key, a sibling of `splunkPlatform`. Both destinations coexist — you are adding, not replacing.

    ```yaml
    clusterName: ${WS_USER}-minikube-cluster

    # [AW2] Second destination. Added without changing how anything is collected.
    splunkObservability:
      realm: "us1"
      accessToken: "${O11Y_TOKEN}"
      metricsEnabled: true
      tracesEnabled: true
      profilingEnabled: true     # enabled later in this module

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

!!! danger "There is no `logsEnabled` here"
    Adding it fails the install:
    ```
    Error: UPGRADE FAILED: values don't meet the specifications of the schema(s)
      at '/splunkObservability': additional properties 'logsEnabled' not allowed
    ```
    Logs reach Observability Cloud through **Log Observer Connect** (step 4), which queries
    Splunk Enterprise directly rather than ingesting a second copy. So there's no toggle.

!!! tip "Validate before you install — this is the one check that fails loudly"
    The chart ships a `values.schema.json`, and it will reject unknown keys. That makes it
    the only validation in this entire workshop that catches a mistake *before* it silently
    does nothing:

    ```bash
    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml --dry-run=client
    ```

    Get into the habit. Almost every other misconfiguration in this workshop deploys
    cleanly and produces nothing.

```bash
cd ~/k8s_workshop/k8s_otel
helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent
```

Confirm the `signalfx` exporters now exist in the running configuration:

```bash
kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
  -o go-template='{{index .data "relay"}}' | grep -E '^\s+signalfx'
```

Start the load test in your second terminal — the rest of this module needs traffic:

```bash
cd ~/k8s_workshop/jmeter
./apache-jmeter-5.6.3/bin/jmeter -n -t petclinic_test_plan.jmx \
  -JPETCLINIC_HOST=minikube -JPETCLINIC_PORT=30000 -Jloops=500 -l results.jtl
```

---

## 3. Find your data in Observability Cloud

### Infrastructure

**Infrastructure → Kubernetes → K8s workloads.** Filter to your cluster,
`${WS_USER}-minikube-cluster`. Nodes, pods and containers appear within a minute or two.

### APM

**APM**, then filter to environment `${WS_USER}-k8s-petclinic-env`.

### ✅ Checkpoint

You should see **two** services:

| Service | What it is |
|---|---|
| `${WS_USER}-k8s-petclinic-service` | your application |
| `h2:…` | the H2 database |

!!! abstract "Learning moment — where did the second service come from?"
    You never instrumented a database. That's an **inferred service**: the Java agent saw
    JDBC calls leaving your application, and Observability Cloud inferred a downstream
    dependency from the spans alone.

    This is why traces matter. The service map assembles itself from what's actually
    happening, rather than from a diagram someone drew and stopped updating.

Your service should show roughly a **6.7% error rate** — the deliberate `/oups` sampler in
the JMeter plan. The same failures you found in Splunk Enterprise in FW #2, now expressed
as a service-level metric.

---

## 4. Connect logs with Log Observer Connect

!!! abstract "Learning moment — query, don't duplicate"
    Log Observer Connect does **not** ingest your logs a second time. It queries the Splunk
    Enterprise indexes you already populated in FW #2, from within the Observability Cloud
    UI.

    So you keep one copy of the data, with Splunk's retention and access control, while
    still being able to jump from a trace to the logs that explain it.

### Network access

Observability Cloud connects *inbound* to your Splunk instance. Open **port 8089** to the
IPs for your realm — for `us1`:

```
44.230.152.35    44.231.27.66    44.225.234.52    44.230.82.104
```

Other realms are listed in
[Splunk's documentation](https://help.splunk.com/en/splunk-observability-cloud/manage-data/view-splunk-platform-logs/set-up-log-observer-connect-for-splunk-enterprise).

### Create the service account role

```bash
sudo -i -u splunk
cat > /opt/splunk/etc/system/local/authorize.conf <<'EOF'
[role_loc_service]
search = enabled
edit_tokens_own = enabled
indexes_list_all = disabled
srchIndexesAllowed = k8s_ws_logs;k8s_ws_petclinic_logs;k8s_ws_traces
srchIndexesDefault = k8s_ws_petclinic_logs
srchJobsQuota = 40
srchDiskQuota = 1000
srchTimeWin = 2592000
srchTimeEarliest = 7776000
EOF
```

!!! danger "Three traps in that one file"
    **1. `indexes_list_all` must be `disabled`.** Earlier versions of this workshop
    *enabled* it. Current Splunk guidance is the opposite.

    **2. There is deliberately no `importRoles`.** Splunk **unions** `srchIndexesAllowed`
    across inherited roles, so `importRoles = user` silently grants `main`, `summary`,
    `history` and every other index that role can reach — while the config still *looks*
    restrictive. Without it, the account gets exactly the three indexes listed.

    **3. `edit_tokens_own` is required.** Log Observer Connect mints its own token when it
    connects. Without this capability the connection fails in a way that looks like bad
    credentials.

**Restart Splunk before creating the user** — roles are only read at startup:

```bash
/opt/splunk/bin/splunk restart
/opt/splunk/bin/splunk add user loc_svc -password '<CHOOSE_A_PASSWORD>' \
  -role loc_service -auth admin:'<YOUR_ADMIN_PASSWORD>'
```

Skip the restart and you get `Could not find role`, which reads like a typo rather than a
timing problem.

### Generate a certificate for the management port

```bash
mkdir -p /opt/splunk/etc/auth/loccerts && cd /opt/splunk/etc/auth/loccerts

/opt/splunk/bin/splunk cmd openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout locKey.pem -out locCert.pem \
  -subj "/C=CA/ST=BC/L=Vancouver/O=Workshop/CN=${PUB_DNS}" \
  -addext "subjectAltName=DNS:${PUB_DNS}"

cat locCert.pem locKey.pem > locServer.pem
```

Point the management port at it, in `/opt/splunk/etc/system/local/server.conf`:

```ini
[sslConfig]
serverCert = /opt/splunk/etc/auth/loccerts/locServer.pem
```

```bash
/opt/splunk/bin/splunk restart
echo | openssl s_client -connect 127.0.0.1:8089 2>/dev/null | openssl x509 -noout -subject
```

!!! note "One certificate, not a chain"
    Earlier versions of this workshop built a root CA and then a server certificate signed
    by it — around fifteen steps. Current documentation only needs the certificate the
    management port presents, so a single self-signed certificate is enough.

### Run the guided setup

**Logs → Logs connections**

![Logs Connections](../assets/img/04-aw2/loc-01-logs-connections-empty.png)

**Add new connection → Splunk Enterprise**

![Choose platform](../assets/img/04-aw2/loc-03-choose-platform.png)

Fill in the service account details. The certificate is the contents of `locCert.pem` —
paste from `-----BEGIN CERTIFICATE-----` to `-----END CERTIFICATE-----` inclusive:

![Service account details](../assets/img/04-aw2/loc-04-service-account-details.png)

| Field | Value |
|---|---|
| Service account username | `loc_svc` |
| Password | the one you chose above |
| Splunk platform URL | `https://$PUB_DNS:8089` — run `echo "https://$PUB_DNS:8089"` |
| Connection name | e.g. `loc_<you>_k8s_otel_workshop` |
| Certificate | contents of `locCert.pem` |

Then choose who may use the connection:

![Configure permissions](../assets/img/04-aw2/loc-05-configure-permissions.png)

### ✅ Checkpoint

![Connection active](../assets/img/04-aw2/loc-06-connection-active.png)

Your connection should list a non-zero index count under **Indexes with access**.

!!! warning "Showing `0/N`? Re-save the connection."
    Log Observer Connect evaluates index access **once, when the connection is created**,
    and caches the result. If you corrected the Splunk role *after* creating the
    connection, it will still show the old answer — commonly `0/7`, which looks like a
    broken setup.

    Open the connection and save it again to force re-evaluation. Nothing on the Splunk
    side needs changing.

Now try it: **Logs**, and search `index=k8s_ws_petclinic_logs`. Those are the events from
FW #2, queried live from Splunk Enterprise.

---

## 5. Make logs correlate with APM

At this point Log Observer can query your logs and APM can show your traces — but the two
don't know about each other. Open **APM → Service Map**, click your service, and look at
the bottom of the panel:

```
Infrastructure (0)          Logs (0)
```

Both zero. Everything is collected correctly; nothing is *linked*.

!!! abstract "Learning moment — correlation is a data contract, not a feature
    Observability Cloud joins logs to services by matching field values. It correlates on
    **`host.name`**, **`service.name`** and **`trace_id`** — and because APM identifies a
    service as *(service name, environment)*, **`deployment.environment`** has to match too.

    Your traces carry all of these, because the Java agent sets them. Your **logs** are
    just container stdout — the Collector knows which pod produced them, but nothing about
    which *service* that is, and the log line has no trace context in it at all.

    So this step is about putting the same four values on both sides.

### Print the trace context in the log line

The Java agent already places `trace_id` and `span_id` into the logging MDC. Spring Boot's
default pattern simply never prints them. Add to the container's `env:` block:

```yaml
        - name: LOGGING_PATTERN_LEVEL
          value: "%5p [trace_id=%X{trace_id:-} span_id=%X{span_id:-}]"
```

??? example "What your manifest should look like around here"
    One entry among the others in the same `env:` list. The comment block above shows what precedes it so you can find the right spot.

    ```yaml
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

Log lines then carry the trace context:

```
2026-08-19T20:22:17.569Z INFO [trace_id=8009da57d52c08b5… span_id=46f93c64e32d8393] …
```

!!! tip "Splunk extracts these for free"
    Because the pattern emits `key=value` pairs, Splunk's automatic field extraction turns
    them into `trace_id` and `span_id` fields with no further configuration. Emitting them
    in that shape is deliberate.

### Put service identity on the logs

The Collector's `k8s_attributes` processor adds `k8s.*` to log records, but nothing that
identifies the *service*. Add to `transform/petclinic_logs`:

```yaml
          - set(resource.attributes["service.name"], "${WS_USER}-k8s-petclinic-service")
              where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
          - set(resource.attributes["deployment.environment"], "${WS_USER}-k8s-petclinic-env")
              where resource.attributes["k8s.container.name"] == "${WS_USER}-petclinic-otel-container01"
```

??? example "What your transform should look like around here"
    These go inside `transform/petclinic_logs.log_statements`, alongside the sourcetype statement you added in FW #2.

    ```yaml
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
    ```

??? abstract "Full command sequence — collector change"
    ```bash
    cd ~/k8s_workshop/k8s_otel
    ne values-workshop.yaml          # or: vi values-workshop.yaml

    # A text editor writes ${WS_USER} literally. Resolve it to your username:
    sed -i "s|\${WS_USER}|$WS_USER|g" values-workshop.yaml
    grep -n "$WS_USER" values-workshop.yaml | head    # confirm

    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml --dry-run=client

    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml

    kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent --timeout=300s
    ```

!!! danger "These must match the span values exactly"
    `service.name` must equal `OTEL_SERVICE_NAME`, and `deployment.environment` must equal
    the value in `OTEL_RESOURCE_ATTRIBUTES`. A typo doesn't error — it just silently fails
    to correlate, which looks identical to not having configured it at all.

    ```bash
    kubectl exec deploy/${WS_USER}-petclinic-otel-deployment -- \
      sh -c 'echo $OTEL_SERVICE_NAME; echo $OTEL_RESOURCE_ATTRIBUTES'
    ```

```bash
helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
kubectl apply -f ~/k8s_workshop/petclinic/k8s_deploy/${WS_USER}-petclinic-k8s-manifest.yml
```

### `host.name` — handled by field aliasing

The fourth field can't be fixed in the Collector. The `splunk_hec` exporter maps the
resource's `host.name` onto Splunk's canonical **`host`** field, so a separate `host.name`
never exists in the index.

**Logs → Configuration → Field aliasing** exists for exactly this. It maps Splunk field
names onto the standard names Observability Cloud expects, and ships with automatic
mappings already enabled — `host`, `hostname`, `event_host` and others all alias to
`host.name`.

!!! tip "Check before you change anything"
    Aliases for `host.name` and `deployment.environment` are usually active by default. If
    correlation isn't working, confirm there rather than assuming — but the cause is more
    often a missing field on the log side than a missing alias.

### ✅ Checkpoint

With the load test running, confirm all four fields on one event:

```
index=k8s_ws_petclinic_logs trace_id=*
| rename "service.name" as svc, "deployment.environment" as env
| table trace_id, severity, svc, env, host
```

<details>
<summary>Expected</summary>

```
trace_id                          severity  svc                          env                      host
cfb192a42a71c0a496a873cfb4c79d44  ERROR     <you>-k8s-petclinic-service  <you>-k8s-petclinic-env  minikube
```

Then prove the join actually resolves — take a `trace_id` from a log and find it in the
trace index:

```
index=k8s_ws_traces "cfb192a42a71c0a496a873cfb4c79d44" | stats count
```
</details>

Now reload **APM → Service Map**, click your service, and the panel should show non-zero
**Logs**. Clicking through opens Log Observer already filtered to that service.

!!! note "Only some logs carry `trace_id` — that's expected"
    Application logs go through logback, so they pick up trace context from the MDC.
    **Tomcat access logs bypass logback entirely** — the access valve writes straight out —
    so they have no MDC and no `trace_id`.

    You'll typically see a small fraction of events with `trace_id` and the rest without.
    Access logs still give you volume, status codes and response times; application logs
    give you the trace linkage. Both matter, for different questions.

!!! warning "Looking at an old time window?"
    Correlation only applies to logs written *after* these fields were configured. If the
    service map still shows zero, narrow the time picker to the last 15 minutes before
    concluding something is wrong.

---

## 6. AlwaysOn Profiling

!!! abstract "Learning moment — beyond which service is slow"
    A trace tells you *which service* spent the time. A profile tells you *which code*. The
    agent samples JVM call stacks continuously and links them to the spans that were active
    — so you can go from a slow endpoint to the exact method underneath it.

Enable it on the Collector:

```yaml
splunkObservability:
  profilingEnabled: true      # was false
```

??? example "What your values file should look like around here"
    `profilingEnabled` flips from `false` to `true`; everything else is unchanged.

    ```yaml

    # [AW2] Second destination. Added without changing how anything is collected.
    splunkObservability:
      realm: "us1"
      accessToken: "${O11Y_TOKEN}"
      metricsEnabled: true
      tracesEnabled: true
      profilingEnabled: true     # enabled later in this module
    ```

??? abstract "Full command sequence — collector change"
    ```bash
    cd ~/k8s_workshop/k8s_otel
    ne values-workshop.yaml          # or: vi values-workshop.yaml

    # A text editor writes ${WS_USER} literally. Resolve it to your username:
    sed -i "s|\${WS_USER}|$WS_USER|g" values-workshop.yaml
    grep -n "$WS_USER" values-workshop.yaml | head    # confirm

    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml --dry-run=client

    helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
      --version 0.158.0 -f values-workshop.yaml

    kubectl rollout status daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent --timeout=300s
    ```

And on the application, in the container's `env:` block:

```yaml
        - name: SPLUNK_PROFILER_ENABLED
          value: "true"
        - name: SPLUNK_PROFILER_MEMORY_ENABLED
          value: "true"
        - name: SPLUNK_PROFILER_OTLP_PROTOCOL
          value: "grpc"
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

!!! danger "The protocol default does not match our endpoint"
    `splunk.profiler.otlp.protocol` defaults to **`http/protobuf`**, and the profiler sends
    to `otel.exporter.otlp.endpoint` — which AW #1 set to **gRPC on port 4317**.

    Mismatched, the profiler starts happily and sends nothing. There is no error. Setting
    `SPLUNK_PROFILER_OTLP_PROTOCOL=grpc` aligns them.

No image rebuild is needed — this is Deployment configuration, not baked into the image:

```bash
helm upgrade ${WS_USER}-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
kubectl apply -f ~/k8s_workshop/petclinic/k8s_deploy/${WS_USER}-petclinic-k8s-manifest.yml
kubectl rollout status deployment/${WS_USER}-petclinic-otel-deployment
```

### ✅ Checkpoint

```bash
kubectl logs deploy/${WS_USER}-petclinic-otel-deployment | grep -A8 'Profiler configuration'
```

<details>
<summary>Expected — check the last two lines especially</summary>

```
Profiler configuration:
              Enabled : true
    ProfilerDirectory : /tmp
    RecordingDuration : 20000ms
         OtlpProtocol : grpc                        ← must match your endpoint
            IngestUrl : http://192.168.49.2:4317
```
</details>

In Observability Cloud: **APM → your service → AlwaysOn Profiling**. With load running,
flame graphs appear within a few minutes.

---

## 7. Real User Monitoring

!!! abstract "Learning moment — the half you cannot see from the server
    Everything so far measures the *server's* view. RUM measures the **browser's**: how
    long the page took to become usable, which resources were slow, what JavaScript errors
    real users hit.

    A request the server answered in 8 ms can still take 4 seconds to become interactive.
    Only the browser knows that.

### Create a RUM token

**Settings → Access Tokens → New Token**, scope **RUM**. This is separate from the ingest
token.

!!! note "This token is served to browsers, by design"
    The RUM token appears in your page's HTML because the browser needs it to send data.
    It's scoped to RUM ingest only and cannot read anything. Don't reuse your INGEST token
    here.

```bash
umask 077
printf '%s' '<YOUR_RUM_TOKEN>' > ~/.rum-token
```

### Add the snippet to the application

RUM is browser-side, so it goes in the page. Edit PetClinic's shared layout,
`src/main/resources/templates/fragments/layout.html`, and insert before `</head>`:

```html
  <!-- Splunk Real User Monitoring -->
  <script src="https://cdn.signalfx.com/o11y-gdi-rum/latest/splunk-otel-web.js"
          crossorigin="anonymous"></script>
  <script>
    SplunkRum.init({
      realm: "us1"          # must match $O11Y_REALM,
      rumAccessToken: "<YOUR_RUM_TOKEN>",
      applicationName: "${WS_USER}-petclinic-rum",
      deploymentEnvironment: "${WS_USER}-k8s-petclinic-env"
    });
  </script>
```

!!! tip "Match `deploymentEnvironment` to your APM environment"
    Using the same value as `OTEL_RESOURCE_ATTRIBUTES` lets Observability Cloud correlate a
    browser session with the backend traces it produced. Different values still collect
    data — they just won't join up.

Rebuild and redeploy. This *does* need a new image, because the change is inside the jar:

```bash
cd ~/k8s_workshop/petclinic/spring-petclinic
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
./mvnw -B -DskipTests package

cd target
eval $(minikube -p minikube docker-env)
docker rmi -f ${WS_USER}/petclinic-otel:v1
docker build --tag ${WS_USER}/petclinic-otel:v1 .
kubectl rollout restart deployment/${WS_USER}-petclinic-otel-deployment
kubectl rollout status  deployment/${WS_USER}-petclinic-otel-deployment
```

### ✅ Checkpoint — is the snippet actually served?

```bash
curl -s http://minikube:30000/ | grep -o 'o11y-gdi-rum\|SplunkRum.init'
```

Both strings must appear. If they don't, the template edit didn't make it into the image —
re-check the build.

### Drive a real browser

RUM only produces data when a **real browser executes the JavaScript**. `curl` and JMeter
cannot do this; they never run the page.

```bash
sudo apt-get install -y python3-venv          # not installed by default on Ubuntu 24.04
```

```bash
python3 -m venv ~/playwright-venv
~/playwright-venv/bin/pip install playwright
sudo ~/playwright-venv/bin/playwright install-deps chromium   # needs root
~/playwright-venv/bin/playwright install chromium             # ~650 MB
```

!!! note "Why Playwright rather than JMeter's WebDriver plugin"
    Earlier versions of this workshop used a custom 111 MB JMeter build bundling the
    WebDriver Set plugin, Selenium, and a pinned `chromedriver` — all locked to one Chrome
    version. Every browser update broke it.

    Playwright installs the browser and its driver as a matched pair, so that whole class
    of version mismatch disappears.

```bash
cd ~/k8s_workshop
curl -fsSLO https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop/main/labs/rum/petclinic_browser_test.py
~/playwright-venv/bin/python petclinic_browser_test.py \
  --url http://minikube:30000 --iterations 6
```

<details>
<summary>Expected output</summary>

```
RUM browser test -> http://minikube:30000   (6 iterations)
  ✓ SplunkRum is initialised in the browser
  iteration 1/6 complete
  ...
Done in 65s. RUM data appears in Observability Cloud within a minute or two.
```

The script checks `SplunkRum` is defined **before** running the journey, so a missing
snippet fails immediately with a clear message rather than producing no data silently.
</details>

### ✅ Checkpoint

**Digital Experience → RUM**, filtered to your application. You should see page views,
load times, and the JavaScript error from `/oups`.

---

## 8. Follow one problem across all four

This is what the whole series has been building toward.

!!! abstract "Learning moment — the pivot
    You now have four views of the same running system: browser sessions, service traces,
    infrastructure metrics, and raw logs. Their value isn't in any one view — it's in
    moving between them without losing your place.

With load running:

1. **APM → your service.** Note the error rate — around 6.7%.
2. **Click into the errors.** Trace Analyzer shows the failing traces; open one and you'll
   see the span for `/oups` marked as an error.
3. **From the trace, pivot to Infrastructure.** The pod, node and container that served
   the request — was the failure isolated, or was the node under pressure?
4. **From the trace, pivot to Logs.** Log Observer Connect queries
   `k8s_ws_petclinic_logs` and shows the `RuntimeException` stack trace — the same one you
   found in FW #2, reachable in two clicks from the error rate.
5. **Digital Experience → RUM.** The browser's side of the same failure.

### ✅ Checkpoint — do the numbers agree?

| Source | Should show |
|---|---|
| JMeter console | ~6.7% failed samples |
| APM service | ~6.7% error rate |
| Splunk Enterprise | matching `RuntimeException` events |

When these disagree, that's a finding in itself: something is being sampled, dropped, or
misrouted. Agreement is what makes the data trustworthy.

---

---

## Reference — complete files at the end of this module

If something isn't behaving, compare your files against these rather than re-reading the
steps. They're the exact files this module was tested with.


??? example "values-workshop.yaml (collector overlay)"
    Placeholders are rendered with `envsubst`; substitute your own values by hand if you prefer.
    ```yaml
    # Splunk OTel Collector — final workshop overlay (FW2 + AW1 + AW2).
    # TESTED end to end on 2026-08-19 against chart 0.158.0.
    #
    # Render:  WS_USER=<you> LOCAL_IP=$(ec2metadata --local-ipv4) \
    #          HEC_TOKEN=<hec> O11Y_TOKEN=<ingest> O11Y_REALM=us1 \
    #          envsubst < values-final.yaml > my-values.yaml
    # Install: helm upgrade <you>-k8s-ws splunk-otel-collector-chart/splunk-otel-collector \
    #            --version 0.158.0 -f my-values.yaml
    #
    # Validate first — the chart schema is the only check that fails loudly:
    #          helm upgrade ... --dry-run=client
    # [FW2] Identifies this cluster on every metric, trace and log.
    clusterName: ${WS_USER}-minikube-cluster

    # [AW2] Second destination. Added without changing how anything is collected.
    splunkObservability:
      realm: "us1"          # must match $O11Y_REALM
      accessToken: "${O11Y_TOKEN}"
      metricsEnabled: true
      tracesEnabled: true
      profilingEnabled: true     # enabled later in this module

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
            docker_image_author: "gerry"
            splunk.com/index: "k8s_ws_petclinic_logs"
        spec:
          containers:
          - name: ${WS_USER}-petclinic-otel-container01
            image: gerry/petclinic-otel:v1
            imagePullPolicy: Never
            ports:
            - containerPort: 8080
            env:
            - name: SPLUNK_OTEL_AGENT
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            - name: OTEL_EXPORTER_OTLP_ENDPOINT
              value: "http://$(SPLUNK_OTEL_AGENT):4317"
            # AlwaysOn Profiling
            - name: SPLUNK_PROFILER_ENABLED
              value: "true"
            - name: SPLUNK_PROFILER_MEMORY_ENABLED
              value: "true"
            # The profiler defaults to http/protobuf on :4318. Our endpoint is gRPC
            # on :4317, so the protocol must be matched or profiling silently fails.
            - name: SPLUNK_PROFILER_OTLP_PROTOCOL
              value: "grpc"
            # Print the trace context the agent puts into the MDC. Without this the
            # log line has no trace_id and APM<->Logs correlation cannot work.
            # PetClinic logs nothing for successful requests — only startup and
            # exceptions. Tomcat access logging gives one line per request, which is
            # what makes the log exercises worth doing.
            # directory=/dev + prefix=stdout with empty suffix writes to /dev/stdout.
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
            - name: LOGGING_PATTERN_LEVEL
              value: "%5p [trace_id=%X{trace_id:-} span_id=%X{span_id:-}]"
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
      https://raw.githubusercontent.com/gdcosta/k8s-otel-workshop/main/labs/collector/values-final.yaml
    diff <(sed 's/[[:space:]]*$//' ~/k8s_workshop/k8s_otel/values-workshop.yaml) \
         <(sed 's/[[:space:]]*$//' /tmp/reference.yaml)
    ```
    The reference is the **final** state after AW #2. Each top-level section is tagged
    `[FW2]`, `[AW1]` or `[AW2]` with the module that introduces it, so ignore anything
    tagged for a module you haven't reached yet.

## ✅ Module checkpoint

```bash
~/k8s-otel-workshop/scripts/verify-aw2.sh
```

---

## Troubleshooting

??? failure "`helm upgrade` fails with a schema error"
    You've added a key the chart doesn't recognise — most often `logsEnabled` under
    `splunkObservability`. The message names the exact path. Run with `--dry-run=client`
    to check before installing.

??? failure "No data in Observability Cloud"
    Test the token directly with the `curl` from step 1. `401` means the token or realm is
    wrong. If that returns `200`, check the Collector:
    ```bash
    kubectl logs daemonset/${WS_USER}-k8s-ws-splunk-otel-collector-agent | grep -iE 'signalfx|401|403'
    ```

??? failure "Log Observer Connect shows 0 indexes"
    Re-save the connection — access is evaluated once at creation and cached. See step 4.

??? failure "Log Observer Connect can see more indexes than expected"
    Your role has `importRoles`. Splunk unions `srchIndexesAllowed` across inherited roles.
    Remove it and restart Splunk.

??? failure "`Could not find role loc_service`"
    Roles load at startup. Restart Splunk between writing `authorize.conf` and creating the
    user.

??? failure "Service map shows Infrastructure (0) and Logs (0)"
    Correlation needs four matching values on the logs: `host.name`, `service.name`,
    `deployment.environment` and `trace_id`. Check them on a recent event:
    ```
    index=k8s_ws_petclinic_logs trace_id=*
    | rename "service.name" as svc, "deployment.environment" as env
    | table trace_id, svc, env, host
    ```
    `service.name` and `deployment.environment` must match the span values exactly —
    compare against `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` in the pod.
    Also narrow the time picker: correlation only applies to logs written *after* the
    fields were configured.

??? failure "Severity column shows UNKNOWN"
    You set a log **attribute** named `severity` rather than the record's severity. Only
    `log.severity_text` and `log.severity_number` drive that column. See FW #2, step 11.

??? failure "Only a fraction of logs have trace_id"
    Expected. Application logs pass through logback and pick up trace context from the
    agent's MDC injection; **Tomcat access logs bypass logback**, so they never have it.

??? failure "Profiling enabled but no flame graphs"
    Protocol mismatch. Check the agent's startup banner:
    ```bash
    kubectl logs deploy/${WS_USER}-petclinic-otel-deployment | grep OtlpProtocol
    ```
    It must match the transport of `OTEL_EXPORTER_OTLP_ENDPOINT` — `grpc` for port 4317.

??? failure "No RUM data"
    Confirm the snippet is served (`curl … | grep SplunkRum.init`), then confirm a real
    browser ran. `curl` and JMeter never execute JavaScript, so neither produces RUM data
    no matter how much traffic they generate.

??? failure "`python3 -m venv` fails with `ensurepip is not available`"
    `sudo apt-get install -y python3-venv`. Ubuntu 24.04 ships Python without it.

---

## Where to go next

You've built a complete observability pipeline: one collector, four signals, two
destinations, and the ability to move between them.

Worth exploring from here:

- **Detectors and alerting** on the error rate you can now see
- **The OpenTelemetry Operator** for auto-instrumentation without rebuilding images
  (`operator.enabled` in the chart)
- **The Kubernetes audit log** as a security data source — see the
  [instructor guide](../instructor/index.md) for ready-made detections
- **Tearing it down** — `helm uninstall`, `minikube delete`, and terminating the instance
