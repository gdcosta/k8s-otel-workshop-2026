# Splunk Kubernetes & OpenTelemetry Workshop

A hands-on workshop: deploy a six-service Java application (Spring PetClinic) to
Kubernetes, lock down its networking with Cilium, and observe it with OpenTelemetry
into Splunk Enterprise and Splunk Observability Cloud.

**📖 Read it as a website:** <https://gdcosta.github.io/k8s-otel-workshop-2026/>
(or browse the Markdown in [`docs/`](docs/) — it renders fine on GitHub too)

Every command in these guides was executed on a live EC2 instance and its output
recorded, rather than transcribed from an older document. That is the project's
one non-negotiable rule; see [`AGENTS.md`](AGENTS.md) if you are contributing.

## The modules

| Module | Time | You will |
|---|---|---|
| [Host setup](docs/00-setup/index.md) | 45 min | Build the Ubuntu host: Docker, minikube, kubectl, Helm, Splunk Enterprise |
| [FW #1](docs/01-foundational-1/index.md) | 1.5 hr | Enable the k8s audit log, build one service and pull the other five, deploy all six |
| [FW #1b](docs/01b-foundational-1b/index.md) | 2.5 hr | Cilium: observe traffic with Hubble, default-deny policies, kube-proxy replacement, Ingress |
| [FW #2](docs/02-foundational-2/index.md) | 2 hr | Deploy the OTel Collector, collect logs, annotations, multiline, OTTL transforms, Hubble flow logs, install the dashboard app |
| [AW #1](docs/03-advanced-1/index.md) | 2 hr | Metrics, operator-based Java auto-instrumentation, traces, index routing, Cilium/Hubble metrics, four capstone dashboards |
| [AW #2](docs/04-advanced-2/index.md) | 2 hr | Observability Cloud: APM, Log Observer Connect, AlwaysOn Profiling, RUM |

Supporting pages, not part of the timed sequence:

| Page | For |
|---|---|
| [Concepts](docs/concepts/) | Containers & Kubernetes, why observability, the Collector & Helm — read-ahead material |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-first index for when a lab step misbehaves |
| [Facilitator guide](docs/facilitator/index.md) | Provisioning, running a session, failure modes ranked by frequency, teardown, maintenance |

## Requirements

- One EC2 instance per participant: **Ubuntu 24.04 LTS, x86-64**, **8 vCPU / 32 GB**, 100 GB gp3
- ARM is not an option — Splunk Enterprise has no Linux ARM64 build
- Inbound: 22, 8000, 8080 (plus 8089 for Log Observer Connect in AW #2)
- Roughly 3 GB of downloads during host setup, mostly Splunk Enterprise

The 8 vCPU / 32 GB spec is not a margin-of-safety guess. FW #1 deploys PetClinic as six
cold-starting Spring Boot services instead of one; tested on 4 vCPU / 16 GB, that startup
drove load average to 66, the kubelet missed its node-lease renewal, and Kubernetes
evicted every pod on the node. 8 vCPU / 32 GB held stable through a three-minute traffic
soak with the node `Ready` throughout — see [`versions.env`](versions.env)'s
`PETCLINIC_MICROSVC_MINIMUM_VCPU`.

See [`versions.env`](versions.env) for every pinned version. Nothing in this workshop
resolves "latest" at install time — two participants on different days must get
byte-identical software.

## The dashboards

The seven capstone dashboards ship as a single installable Splunk app, downloaded once
in FW #2 §13. AW #1 and AW #2 then open dashboards the participant already has.

| Dashboard | Filled in by |
|---|---|
| Foundational Workshop 2 — What You Built | FW #2 |
| Foundational Workshop 2 — Hubble Flow Logs | FW #2 |
| Advanced Workshop #1 — Metrics & Traces | AW #1 |
| Advanced Workshop #1 — Infrastructure & Collector Health | AW #1 |
| Advanced Workshop #1 — Cilium & Hubble Metrics | AW #1 |
| Advanced Workshop #2 — Correlation | AW #2 |
| Application Trace Information v4.0.0 | AW #1 |

AW #2 additionally imports a Splunk Observability Cloud dashboard
(`labs/dashboards/aw2-o11y-dashboard.json`) — a Splunk app cannot carry Observability
Cloud content, so that one stays a separate import.

**The XML files in `labs/dashboards/` are the source of truth.** The installable
`.tgz` under `labs/dashboards/dist/` is a build artifact:

```bash
bash scripts/build-dashboard-app.sh
```

Edit a dashboard without rebuilding and participants install the old one — the guides
link to the tarball, not to the XML.

## Verifying your progress

Each module ships an assertion script. They are also the check to run against new
Collector chart releases.

```bash
export WS_USER=<your-username>
./scripts/verify-fw1.sh
```

`verify-setup.sh`, `verify-fw1.sh`, `verify-fw1b.sh`, `verify-fw2.sh`, `verify-aw1.sh`
and `verify-aw2.sh` cover the six modules.

## Repository layout

```
docs/                 the guide (Markdown; also the MkDocs site source)
docs/assets/img/      screenshots, with an inventory + status in manifest.yml
labs/                 real files downloaded during the labs
  collector/            Collector Helm overlays
  dashboards/           the seven capstone dashboards (source of truth)
  dashboards/app/       Splunk app skeleton — app.conf, nav, metadata
  dashboards/dist/      built .tgz (build artifact, committed so guides can curl it)
  dockerfiles/          PetClinic container build
  jmeter/               one-off JMeter load plan (FW #2)
  loadgen/              always-on in-cluster Playwright load generator
  manifests/            Kubernetes manifests
  rum/                  Playwright browser-load script for RUM
scripts/              bootstrap, verification, and the site/app builders
versions.env          every pinned version, in one place
mkdocs.yml            site config (mkdocs-offline.yml builds the offline variant)
```

## Building the site locally

```bash
python3 -m venv .venv && source .venv/bin/activate
source versions.env
pip install "mkdocs-material==${MKDOCS_MATERIAL_VERSION}"
mkdocs serve                      # http://127.0.0.1:8000
mkdocs build --strict             # what CI enforces — must pass
```

To produce fully self-contained HTML (CSS, JS and images inlined; works from a
network share, USB stick or email attachment, no web server):

```bash
bash scripts/build-standalone.sh  # -> docs-standalone/
```

## Status

Rebuilt from the original v3.0.1 Word guides. The last **full fresh-instance run of all
modules end to end** was **2026-08-21**, against the original single-pod PetClinic.

Since then the application moved to six microservices and the guides were reworked to
match (FW #1b is new). That work lives on the `migrate/petclinic-microservices` branch and
has been validated module by module on live instances (the FW #2, AW #1 and AW #2
`verify-*.sh` scripts passing) — but it has **not** had a recorded full fresh-instance run, and it is not merged
to `main`. The guides download labs files from `main`, so merge before publishing.

Known gaps, tracked honestly rather than quietly:

- **Screenshots** carried over from the original Word guides are marked `stale` in
  `docs/assets/img/manifest.yml`. There is currently **no on-page staleness banner**, and
  most of the inherited images are no longer referenced by the rewritten guides at all.
  The dashboard screenshots are re-captured and `verified`.
- **Concepts pages** have not been fact-checked against current product behaviour.

## Author

Gerry D'Costa — Staff Solutions Engineer, Splunk
