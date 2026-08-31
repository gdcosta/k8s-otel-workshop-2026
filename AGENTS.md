# Working in this repository

Instructions for coding agents (Cursor, Claude Code, and anything else that reads
`AGENTS.md`). Read this before editing. Most of what follows is **not inferable from
the files** — it is the reasoning behind how they are built.

This repo is a **workshop guide**, not an application. The deliverable is prose and
lab files that a room of participants will follow literally, on their own EC2
instances, while a facilitator watches. A wrong command here does not throw a stack
trace — it strands twenty people at once.

---

## In progress: migrating PetClinic from a monolith to six microservices

`main` is fully consistent and works end to end — this migration lives on
`migrate/petclinic-microservices` until it's finished, specifically so a partial,
inconsistent state never lands on `main`. If you're reading this on that branch,
here's where things stand:

- **Phase 0 (feasibility) and Phase 1 (FW #1) are done and tested.** FW #1 now builds
  `customers-service` by hand and deploys all six services, in their own `petclinic`
  namespace (not `default`), via `labs/manifests/petclinic-microservices.yml`.
  `versions.env`, `scripts/verify-fw1.sh`, and the instance-size requirement (bumped to
  8 vCPU / 32 GB — see below) are updated and consistent with FW #1's new content. If
  FW #2/AW1/AW2 get their own migration pass later, their `kubectl` commands need
  `-n petclinic` added too — grep those docs for bare `kubectl get/logs/exec` touching
  PetClinic before assuming `default` still works.
- **Phase 2 (FW #2, the Collector rework) is done and tested.** All four Collector
  overlays (`labs/collector/values-{workshop,aw1,final,aw2}.yaml`) are re-cut: OTTL
  predicates now key on `resource.attributes["k8s.namespace.name"] == "petclinic"`
  instead of one exact container name, `extraAttributes.fromLabels` promotes each pod's
  `app.kubernetes.io/name` to `service.name` (verified live: k8sattributes doesn't
  overwrite an attribute that already exists, so agent-instrumented traces keep their
  real name and only scraped logs get the promoted one), and multiline recombine is
  scoped to the `petclinic` namespace rather than one container — verified live with a
  real multi-line `TransportException` (44–50 lines) recombining correctly across five
  different services. The two hardcoded `service.name`/`deployment.environment`
  statements in `values-final.yaml`/`values-aw2.yaml` are gone; leaving them would have
  silently overwritten the per-service names the label promotion just set, since
  `k8s_attributes` runs before that transform in the pipeline. **The metrics/traces
  predicates in aw1/final/aw2 were changed the same way but NOT independently verified
  live** — only logs were exercised this phase; confirm those three when AW1 is rebuilt.
  `scripts/verify-fw2.sh` is rewritten and passes 16/16 live. A new
  `labs/manifests/petclinic-microservices-fw2.yml` captures the FW2 end state (adds
  Tomcat access logging to `customers-service` only — see FW2 §6 for why one service is
  enough).
- **Phase 3 (load-generator rewrite) is done and tested.** `labs/jmeter/petclinic_test_plan.jmx`
  now hits the real gateway REST routes — every path, method, and POST/PUT body was
  captured from a real browser session against the deployed app with Playwright request
  interception, not inferred from source (`/api/gateway/owners/{id}`, a composite
  endpoint the gateway itself implements, would have been easy to miss guessing).
  `labs/rum/petclinic_browser_test.py` is rewritten for the SPA's AngularJS hash routing
  (`#!/owners/details/1`, not `#!/owners/1` — the wrong guess silently falls through to
  the app's `otherwise('/welcome')` catch-all with no error at all). There is no `/oups`
  equivalent and none was added — the fault is external: `kubectl scale
  deployment/visits-service -n petclinic --replicas=0`, documented in FW #2 §8, which the
  gateway answers with a real, fast `503`. FW #2 §7–8 are rewritten with real numbers
  from that exact run: JMeter's own rate is a clean **28.57%** (2 of 7 samplers touch
  `visits-service`); Splunk-side, `api-gateway`'s own logs show 242 events (222 `WARN`
  "no servers available", 20 multi-line `ERROR` `NoRouteToHostException`) for those same
  90 failed requests — genuinely more than one log line per failure, not a bug, and
  written up as a second, deeper instance of the module's own "what you count decides
  whether you agree" lesson. `PUT /api/customer/owners/{id}` requires the **full** owner
  object including its `pets` array back, or it looks destructive — the test plan
  round-trips a captured JSON body via a JSR223 PostProcessor rather than risk corrupting
  seed data other exercises depend on.
- **Phase 4 (AW #1 doc rewrite) is done and tested for the sections it touches.**
  `docs/03-advanced-1/index.md` §3–4 replace the old hand-built `-javaagent` + Dockerfile
  approach with the OpenTelemetry Operator's admission webhook
  (`operator.enabled`/`instrumentation.enabled` in `labs/collector/values-aw1.yaml`,
  patching each Deployment with `instrumentation.opentelemetry.io/inject-java`) — chosen
  because five of the six services are pulled images with no Dockerfile to edit, so the
  old approach could not generalize past `customers-service`. Verified live end to end on
  the spike instance 2026-08-29: identical init container and env wiring on both a
  hand-built (`customers-service`) and a pulled (`vets-service`) image; JVM metrics and
  traces both confirmed flowing with real numbers. Two real, non-obvious findings from
  that spike, both now in the doc and in `values-aw1.yaml`'s comments: (1) `helm upgrade
  --install` needs a top-level `environment:` string once `operator.enabled` +
  `tracesEnabled` + `agent.enabled` are all true — a real schema guard; (2) a fresh
  install can lose a one-time race against the operator's own webhook on the very first
  `helm upgrade`, self-resolved by waiting for the operator pod Ready and re-running the
  same command; (3) traces silently land in `k8s_ws_petclinic_logs` instead of
  `k8s_ws_traces` unless `transform/traces_index` is present — the namespace's own
  `splunk.com/index` log-routing annotation gets picked up by the shared
  `k8s_attributes` processor for every signal, not just logs, with zero export error
  either way. §1's `/oups`-based fault framing (obsolete since Phase 3 removed it) is
  corrected to point at FW #2 §8's `kubectl scale visits-service --replicas=0` instead.
  §6's trace example and SPL were captured and verified live, including one caught wrong
  guess (`resource.attributes{}.value.stringValue` for `service.name` — wrong;
  `service.name` is its own top-level indexed field, confirmed via `fieldsummary` before
  it shipped). `scripts/verify-aw1.sh` is rewritten (operator health, per-service
  injection check on both a built and pulled image, signal-flow checks) and passes
  10/10 live. **NOT yet done in this pass:** §2/§7/§8's numeric checkpoints (JVM metric
  family counts, per-route latency tables, dashboard panel counts/screenshots) —
  believed still accurate (they catalog metric *names*, not per-service instance counts,
  so six services shouldn't change them) but not independently re-verified against the
  live six-service topology, and `labs/dashboards/*.xml` themselves are untouched pending
  the separate dashboards-rework phase.
- **Phase 4b (AW #2 doc rewrite) is done and tested, using sub-agents for the live
  validation, config/script finalization, and doc-writing passes** — a deliberate change
  in working method partway through this migration, to keep long live-debugging spikes
  out of the main session's context window. Three technical additions on top of AW #1's operator
  approach, all verified live on the spike instance: **Observability Cloud export**
  (`splunkObservability` layered on the existing operator config — 706 spans, 8,913+713
  metric points delivered, zero failures); **AlwaysOn Profiling and log correlation**,
  both moved from hand-written manifest env vars to `instrumentation.spec.java.env` in
  `labs/collector/values-aw2.yaml` — the same env-injection mechanism AW #1 established,
  now carrying `SPLUNK_PROFILER_*` and `LOGGING_PATTERN_LEVEL`; and **RUM**, whose
  snippet-injection mechanism had the same problem AW #1's Java-agent attach did:
  `api-gateway` (which serves the AngularJS SPA) is a pulled image with no Dockerfile.
  Fixed with a new `scripts/inject-rum-snippet.sh` — extracts the live-served
  `index.html` (never a static copy baked into the repo, since a pulled image's content
  isn't this repo's to own), inserts the snippet, mounts it back via a `ConfigMap` +
  `subPath` volume patch on `api-gateway`. Three real, non-obvious findings from this
  phase: (1) `instrumentation.spec.java.env` **replaces**, not merges, the chart's own
  default env list — omitting the chart's two defaults when adding AW2's four silently
  drops them, no error; (2) the profiler's `SPLUNK_PROFILER_OTLP_PROTOCOL` needed
  `http/protobuf`, not the `grpc` earlier revisions used — the operator's own default
  `OTEL_EXPORTER_OTLP_ENDPOINT` is HTTP on `:4318`, not gRPC on `:4317` like the old
  hand-built approach, and the mismatch fails silently (caught by `verify-aw2.sh` itself
  failing, not by inspection); (3) a `deployment.environment`/`deployment.environment.name`
  split flagged as an open question in `values-aw1.yaml`'s comments was resolved by
  reconciling both onto one value in `values-aw2.yaml`'s OTTL, since this module is
  specifically about correlation fields matching exactly. `scripts/verify-aw2.sh` is
  rewritten (per-service profiling/correlation checks, `/oups`-free warmup) and passes
  17/17 live, including a real Playwright-driven RUM initialization check. §8's
  three-way error-rate reconciliation now uses FW #2 §8's `visits-service` fault
  (JMeter 28.57%, Splunk 242 events) instead of the retired `/oups` sampler — APM's own
  percentage for that fault is **honestly left unmeasured**: this pass had no
  Observability Cloud UI/API/MCP access to query it (the ingest token confirmed working
  for writes returns 401 against the SignalFlow query API, as expected — different
  scope), and the doc says so rather than inventing a plausible number. **NOT yet done:**
  §3's/§9's dashboard-adjacent numeric claims beyond what's called out above, and
  `labs/dashboards/aw2-dashboard.xml`/`aw2-o11y-dashboard.json` themselves, both still
  pending the separate dashboards-rework phase (confirmed topology-independent by direct
  read of the Splunk-side XML, not yet re-verified for the Observability Cloud JSON).
  **Do not run FW #2 through to AW #2 on a live instance right now and expect the
  dashboards to reflect the current topology** — that gap is expected mid-migration.
- **Post-4b scope correction, done and tested: AW #1 now instruments all six PetClinic
  services by default, not two.** User-directed, with the reasoning worth preserving:
  the original "patch `customers-service`/`vets-service` as a minimum proof, extend if
  you want" framing in AW #1 §3 was inherited straight from the old monolith's shape —
  one app plus one inferred database dependency — and never got re-examined after the
  migration to six real services, undermining the entire point of the migration (a real
  six-node service map). `docs/03-advanced-1/index.md` §3's `kubectl patch` loop and
  every downstream checkpoint now cover all six; `docs/04-advanced-2/index.md`'s
  profiling/correlation checkpoints and its service-map checkpoint follow the same
  change. Confirmed live, all six carry the injection annotation and report their own
  `service.name`, `jvm.*` metrics and real spans — including the two infrastructure
  services (`discovery-server`, `config-server`), which needed no different treatment
  than the four business services (`config-server` correctly has no
  `wait-for-config-server` init container, since it doesn't wait on itself).

  Also fixed in this pass, same user direction: the meaningless **"localhost" node**
  cluttering the Observability Cloud service map. Root cause is PetClinic's own bundled
  Zipkin auto-export (Spring Boot Actuator's `ZipkinAutoConfiguration`/Micrometer
  Tracing — a completely separate mechanism from the OTel Java agent), continuously
  failing to reach a Zipkin collector at `localhost:9411` that never existed — confirmed
  live at 17,294 failing spans in a 12h window before the fix. Two plausible env vars
  were tried and confirmed live NOT to work
  (`MANAGEMENT_ZIPKIN_TRACING_EXPORT_ENABLED`, `MANAGEMENT_TRACING_ENABLED`) before
  landing on the one that does: `SPRING_AUTOCONFIGURE_EXCLUDE=org.springframework.boot.
  actuate.autoconfigure.tracing.zipkin.ZipkinAutoConfiguration`, added to
  `instrumentation.spec.java.env` in `values-aw1.yaml` (introduced there for the first
  time — AW1 had been running on pure chart defaults until now) and carried forward into
  `values-aw2.yaml`. Confirmed live: 80 → 44 → 0 `localhost:9411` spans across
  iterations, with real HTTP/DB spans and `jvm.*` metrics unaffected throughout. Bonus
  finding along the way, not something this workshop needs to fix: the upstream sample
  app's own bundled ConfigMap sets `management.tracing.export.zipkin.endpoint` — an
  older, pre-Micrometer property path that silently never applies on this Spring Boot
  version, which is *why* the noise heads to `localhost` rather than the real host the
  ConfigMap actually names.

  `labs/collector/values-final.yaml` turned out to be genuinely stale in the same sweep —
  last touched before the operator rewrite (Phase 4a/4b) even though FW #2's own doc
  links it as the "final state" reference; it was missing the entire
  `environment:`/`operatorcrds:`/`operator:`/`instrumentation:` block. Brought to full
  parity with `values-aw2.yaml` and live-tested (dry-run plus a real install, confirmed
  via `/actuator/env` and direct Splunk queries, not dry-run alone).

  `scripts/verify-aw1.sh` (15/15 live) and `scripts/verify-aw2.sh` (30/30 live) both
  expanded their per-service loops to all six and added a Zipkin-noise assertion each.
  One operational finding worth carrying forward: restarting or patching all six
  Deployments **simultaneously** transiently overloaded the control plane on this
  instance size (even a plain `kubectl get pods` timed out for a few seconds, recovering
  on its own) — the same concurrent-cold-start pressure FW #1 found with the original
  six-pod deploy, now showing up again with six JVMs each also loading a Java agent.
  Both docs' patch/restart instructions now stage services one at a time with a
  `rollout status` wait between each, rather than issuing all six as a tight parallel
  batch. This pass used sub-agents throughout (live validation/config finalization, then
  doc-writing), continuing the working-method change from Phase 4b.

  A follow-on pass, same day, found and fixed a **third**, unrelated `localhost` source
  the same way: every PetClinic service's default Spring profile briefly calls
  `http://localhost:8888/<app>/<profile>` at startup and fails, before a second,
  successful call resolves the real `config-server`. Root cause confirmed by reading the
  actual upstream `spring-petclinic-microservices` v3.2.0 source (identical across all
  six services), not guessed: the default profile imports config via
  `spring.config.import: optional:configserver:${CONFIG_SERVER_URL:http://localhost:8888/}`,
  while the `docker` profile's own import is already hardcoded correctly to
  `config-server:8888` — Spring merges `spring.config.import` across active profiles
  rather than one replacing the other, so both fire every restart. First guess
  (`SPRING_CLOUD_CONFIG_URI`) was wrong, confirmed live via the app's own `Connection
  refused` logging still firing with it set. `CONFIG_SERVER_URL` — the literal env var
  name the app's own placeholder reads — is the real fix; added to
  `instrumentation.spec.java.env` in `values-aw1.yaml` (canonical), carried into
  `values-aw2.yaml`/`values-final.yaml`. Confirmed live on both a hand-built
  (`customers-service`) and pulled (`visits-service`) image: 0 `localhost:8888` spans
  after the fix, config still genuinely loads (`/actuator/health` stays `UP`, not just
  "no error"). `scripts/verify-aw1.sh`/`verify-aw2.sh` each got a stricter assertion than
  the Zipkin one — exactly 0 spans expected, not "under 5", since this fix eliminates the
  noise entirely rather than reducing its volume.

  **The `discovery-server` Eureka self-loop (`localhost:8761`, peer replication) was
  deliberately left alone**, on direct user reconsideration mid-cleanup-pass: a fix was
  scoped (disable `eureka.client.register-with-eureka`/`fetch-registry` — but *only* on
  `discovery-server`, since the other five genuinely need Eureka client behavior on to
  find each other, meaning `instrumentation.spec.java.env`'s uniform-application model is
  the wrong mechanism for it entirely) and live investigation had started, then explicitly
  stopped before anything was applied. Reasoning, in the user's own words: this
  workshop's audience isn't app developers and "I don't want to overwhelm them with small
  concepts like this" — the existing AW #2 §3 callout explaining the self-loop (real,
  legitimate Eureka behavior, told apart from the Zipkin/config-client noise by port) is
  judged to serve the workshop better than removing the underlying behavior would.
  Confirmed nothing was changed on `discovery-server` before the drop landed. If this
  gets revisited later, the constraint above (per-service, not uniform) is the reason a
  naive copy of the Zipkin/config-client pattern won't work for it.
- **Two real bugs were found and fixed during Phase 1, worth knowing before you touch
  the manifest again:** Config Server defaults to a live, unpinned `git pull` from
  GitHub on every restart (fixed via the `native` profile + a baked-in ConfigMap — see
  the manifest's header comment); and a hand-built service that's missing
  `ENV SPRING_PROFILES_ACTIVE=docker` binds to a random port with no error message at
  all. Both are documented as `!!! danger` callouts in FW #1 §5–6 — read those before
  assuming a service that "just isn't reachable" is a network problem.
- **The instance-size requirement genuinely changed, confirmed by testing, not
  padding.** 4 vCPU / 16 GB was tested and failed: the kubelet missed its node-lease
  renewal under six simultaneous cold starts and Kubernetes evicted every pod on the
  node. 8 vCPU / 32 GB held stable through a soak. `README.md`, `docs/index.md`,
  `docs/facilitator/index.md`, and `docs/00-setup/index.md` are all updated to match —
  if you touch instance sizing anywhere, grep for `4 vCPU` and `t3.xlarge` first to
  catch what you missed; that grep is how two stale references were caught here.
- **A corporate security agent (Nessus) on the validation EC2 instances is not part of
  the documented workshop AMI.** It caused a control-plane thrashing episode during
  Phase 1 testing that looked alarming but was an artifact of that specific test box,
  not the architecture — the clean, isolated validation run (six services, single
  `kubectl apply`, zero restarts, 72 seconds to ready) is the number that went in the
  guide. Don't mistake a noisy validation instance for a real defect; check what's
  actually consuming CPU before concluding the app is at fault.
- Remaining phases (dashboards rework, Cilium) are unstarted. See the migration plan for
  the full phase breakdown and gates.
- **Considered and rejected: switching FW1 to Splunk's own reference PetClinic
  microservices deployment** (`splunk/observability-workshop`, "Ninja Workshops" ->
  `automatic-discovery` -> `petclinic-kubernetes`). Its images
  (`quay.io/phagen/spring-petclinic-*`) are stale — most untouched since December 2023
  — versus the actively-maintained upstream `springcommunity/*` images already used
  here. Their reference architecture also adds MySQL, `admin-server`, an in-cluster
  load generator, and public unauthenticated HTTP exposure on ports 80/81/443 — the
  last of which contradicts this repo's deliberate security-group + SSH-tunnel
  posture and would need rejecting regardless of the rest. **One idea from it WAS
  adopted separately, in Phase 4:** the OTel Operator's annotation-based
  auto-instrumentation (`kubectl patch` adding
  `instrumentation.opentelemetry.io/inject-java`) instead of a hand-built
  `-javaagent` Dockerfile — not just simpler, but the only approach that generalizes
  once five of the six services are pulled images with no Dockerfile, independent of
  the app/image decision above. See the Phase 4 bullet for the live-verification
  details.
- **In-cluster load generation — deliberately deferred, not rejected.** Considered
  moving JMeter into the cluster as a Deployment (mirroring Splunk's reference
  workshop) to remove participant setup. Decided against making it FW2's primary
  path: bundling it into the same `kubectl apply` as the six app services would
  reintroduce exactly the concurrent-cold-start pressure Phase 0 spent real effort
  de-risking, and a dead in-cluster pod is a much less legible failure for a
  facilitator watching many participants than "is your second terminal still
  running" is today. External JMeter (already the design) stays primary. If it gets
  built later, it must be introduced *after* the app is already confirmed healthy —
  never in the initial deploy — the same timing FW2 §7 already uses for JMeter.
- **Phase 6 (Cilium/Hubble) idea, captured before it's forgotten: a misconfigured
  `CiliumNetworkPolicy` between two pods as a second fault scenario, distinct from
  FW2 §8's `visits-service` scale-to-zero.** User's own observation, 2026-08-31 — worth
  building once Cilium actually exists in the cluster, not before. The two faults fail
  at genuinely different layers, which is the pedagogical point: scale-to-zero is a
  *service-discovery* failure (Eureka has no healthy instance, so Spring Cloud
  LoadBalancer fails fast before attempting a connection — "no servers available", no
  traffic ever leaves the caller). A blocked `NetworkPolicy` would be a *network-layer*
  failure instead — the destination pod is running and still correctly registered in
  Eureka, so the LoadBalancer picks it and genuinely tries to connect, and the packet
  just gets dropped at the CNI layer. That produces connection timeouts rather than a
  clean fast-fail, and is a much more true-to-production "everything looks healthy and
  it still doesn't work" class of bug — exactly what Hubble's flow visibility exists to
  diagnose, and something the current fault has no equivalent demonstration of. Do not
  build this exercise without Cilium actually deployed and the policy actually tested
  live — same "tested, not transcribed" rule as everything else here.

---

## The prime directive: tested, not transcribed

**Every command, flag, path, SPL query and expected output in `docs/` was executed on
a live instance and its real output recorded.** Nothing is written from memory,
inferred from documentation, or carried over from the original Word guides untested.

This is the rule an LLM will most confidently break, because writing a plausible
command is easy and verifying one is slow. Resist it.

- Do **not** add a command to the docs you have not run.
- Do **not** state an expected output you have not seen.
- Do **not** "fix" a documented value to what it *should* be. If the doc and reality
  disagree, reality wins and the discrepancy is usually the interesting finding.
- If you cannot test something, say so plainly and leave it flagged. An honest gap is
  worth far more than a confident guess.

Real examples of what testing catches, all of which looked fine on the page:

- An `mstats … | timechart` pipe that returned **zero rows silently** — no error, just
  an empty chart. Fixed with `xyseries`.
- A `splunk http create` command that does not exist. The real one is
  `splunk http-event-collector create … -uri https://localhost:8089`.
- JMeter `-J` flags being ignored because the `.jmx` had no `__P()` references, so
  every participant silently got the default load regardless of what they typed.
- A dashboard column painting **every** cell red, including the nine rows showing zero
  errors, because the palette was a fixed list rather than a threshold.

None of these are visible by reading. All were caught by running it and looking.

---

## Hard rules

### 1. `versions.env` is the only place versions live

Every pinned version — OS, kubectl, Helm, Splunk, the OTel chart, JMeter, gitleaks,
mkdocs-material, the dashboard app — is defined there and read by docs and scripts.

Change a version there and nowhere else. **Never** resolve `latest`, `stable.txt`, or
an unpinned `pip install` at install time: two participants on different days would
get different software, and the guide's recorded output would stop matching.

### 2. `labs/dashboards/*.xml` is source of truth; the `.tgz` is a build artifact

The five capstone dashboards are authored as XML. `labs/dashboards/app/` holds only
the app skeleton (`app.conf`, nav, metadata). The installable tarball is generated:

```bash
bash scripts/build-dashboard-app.sh     # -> labs/dashboards/dist/k8s-ws-dashboards-<ver>.tgz
```

The build copies the XML in fresh and parses every view, so a malformed edit fails the
build rather than shipping.

**Edit a dashboard and forget to rebuild, and participants install the old one** — the
guides `curl` the tarball from `raw.githubusercontent.com`, not the XML. If the app's
contents change, bump `WORKSHOP_APP_VERSION` in `versions.env`; that changes the
filename, so grep the docs for the old version string and update the URLs.

`labs/dashboards/apm-traces-dashboard.xml` is **Application Trace Information v4.0.0**,
kept byte-for-byte as released. Do not edit it. A modified file still claiming to be
v4.0.0 would be a lie, which is why it is the one dashboard without the added
"fills in during AW #1" banner.

### 3. This repository is public, and some credentials are published on purpose

Secret scanning is a release gate (`.github/workflows/secret-scan.yml`, gitleaks
pinned via `versions.env`, runs on push and on demand).

`Workshop2026!` and `LogObserver2026!` are **fixed lab credentials, published
deliberately**, and allowlisted in `.gitleaks.toml`. They are safe because they only
work against a disposable instance whose port 8000 is scoped to the participant's own
IP. **Do not "helpfully" scrub, rotate or parameterise them** — the guides depend on
every participant having the same password, and a facilitator cannot debug twenty
different ones.

Everything else is a real secret and must never enter the repo, a commit message, or
the terminal transcript:

- Observability Cloud ingest and RUM tokens
- HEC tokens (they are UUIDs — grep for the pattern before committing)
- `.pem` keys, instance IPs tied to a live host

The established practice is that tokens live in files **outside the repo**
(`~/.o11y-token`, `~/.rum-token`), `chmod 600`, written with `printf`, and passed by
`--set` or `$(cat …)` at install time so the value never appears in a document.

### 4. `mkdocs build --strict` must pass

It is the CI gate and it fails on broken links and missing images. Run it before
committing:

```bash
./.venv/bin/mkdocs build --strict
```

If you touch cross-module links, verify the anchor actually exists in the built HTML —
`--strict` does not catch every bad fragment.

### 5. Terminology: **facilitator**, never "instructor"

Throughout docs, scripts and comments. When renaming, watch the article: a blind
find-and-replace produced "an facilitator" three times.

### 6. Do not add CI workflows, schedules or automation unprompted

The two workflows that exist (`docs.yml`, `secret-scan.yml`) are the ones that are
wanted. A third was added speculatively and removed at the maintainer's request, along
with a weekly cron. **Scans and builds run on push and on demand — not on a schedule.**
If you think automation would help, propose it; do not create it.

---

## Repository map

```
docs/                 the guide — Markdown, also the MkDocs source
  00-setup … 04-*/      the five timed modules
  concepts/             read-ahead material (NOT yet fact-checked — see Known gaps)
  facilitator/          provisioning, running a session, failure modes, maintenance
  troubleshooting.md    symptom-first index
  assets/img/           screenshots + manifest.yml inventory
labs/                 real files participants download during the labs
scripts/              bootstrap, per-module verification, site and app builders
versions.env          every pinned version
mkdocs.yml            site config; mkdocs-offline.yml builds the offline variant
```

Working notes from the clean-room walkthroughs (`WALKTHROUGH-FINDINGS*.md`) are kept
**outside** the repo on purpose — they contain live instance details and are drafting
material, not deliverables.

---

## Testing against a live instance

Guides are validated on a real EC2 host. Conventions that will otherwise waste your time:

- The AMI is hardened: **log in as `ubuntu`**, then `sudo -i -u splunk` to reach
  Splunk. Direct `splunk@` SSH is blocked by an `AllowGroups` restriction.
- SSH needs the key explicitly: `ssh -i ~/.ssh/<key>.pem ubuntu@<ip>`. Omitting `-i`
  is the single most common self-inflicted failure.
- **Splunk Web is HTTP on port 8000**, not HTTPS. The management port 8089 is HTTPS
  with a self-signed cert, so CLI calls need `-k` and print a TLS warning that is
  expected boilerplate, not an error.
- Installing a dashboards-only Splunk app needs **no restart** — verified.
- JMeter's process shows up as `java`, so `pgrep -f ApacheJMeter` finds nothing.

---

## Writing style

Match the surrounding prose; it is deliberate and consistent.

- Explain **why**, not just what. A step that says "run this" without saying what it
  proves is a step participants cannot debug.
- Prefer showing the failure and its fix over describing success abstractly. The
  guides routinely say "this looks broken and isn't, here is why."
- Use MkDocs Material admonitions (`!!! note`, `!!! warning`, `??? abstract` for
  collapsed detail). Long alternatives and reference files go in collapsed blocks so
  the main path stays readable.
- British/neutral spelling is used in places; do not mass-convert either direction.
- Screenshots are inventoried in `docs/assets/img/manifest.yml` with a `status`
  (`review` / `stale` / `verified`). Add an entry when you add an image.

---

## Known gaps

Stated so you do not have to rediscover them, and do not paper over them:

- 204 screenshots inherited from the original Word guides are `stale` and carry a
  visible banner until re-captured. Only the five dashboard screenshots are `verified`.
- The `docs/concepts/` pages have never been fact-checked against current product
  behaviour.
- The Observability Cloud dashboard has no screenshot — capturing it needs an
  authenticated browser session against Observability Cloud.
- One facilitator-guide security detection returns a false clean because of a
  `k8sObjects: pods` capture gap.
