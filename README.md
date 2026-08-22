# Splunk Kubernetes & OpenTelemetry Workshop

A four-part, hands-on workshop: containerise a Java application, deploy it to
Kubernetes, and observe it with OpenTelemetry into Splunk Enterprise and Splunk
Observability Cloud.

**📖 Read it as a website:** <https://gdcosta.github.io/k8s-otel-workshop-2026/>
(or browse the Markdown in [`docs/`](docs/) — it renders fine on GitHub too)

Every command in these guides was executed on a live EC2 instance and its output
recorded, rather than transcribed from an older document. That is the project's
one non-negotiable rule; see [`AGENTS.md`](AGENTS.md) if you are contributing.

## The modules

| Module | Time | You will |
|---|---|---|
| [Host setup](docs/00-setup/index.md) | 45 min | Build the Ubuntu host: Docker, minikube, kubectl, Helm, Splunk Enterprise |
| [FW #1](docs/01-foundational-1/index.md) | 1.5 hr | Enable the k8s audit log, build & containerise PetClinic, deploy it |
| [FW #2](docs/02-foundational-2/index.md) | 2 hr | Deploy the OTel Collector, collect logs, annotations, multiline, OTTL transforms, install the dashboard app |
| [AW #1](docs/03-advanced-1/index.md) | 2 hr | Metrics, JVM auto-instrumentation, traces, index routing, three capstone dashboards |
| [AW #2](docs/04-advanced-2/index.md) | 2 hr | Observability Cloud: APM, Log Observer Connect, AlwaysOn Profiling, RUM |

Supporting pages, not part of the timed sequence:

| Page | For |
|---|---|
| [Concepts](docs/concepts/) | Containers & Kubernetes, why observability, the Collector & Helm — read-ahead material |
| [Troubleshooting](docs/troubleshooting.md) | Symptom-first index for when a lab step misbehaves |
| [Facilitator guide](docs/facilitator/index.md) | Provisioning, running a session, failure modes ranked by frequency, teardown, maintenance |

## Requirements

- One EC2 instance per participant: **Ubuntu 24.04 LTS, x86-64**, 4 vCPU / 16 GB, 100 GB gp3
- ARM is not an option — Splunk Enterprise has no Linux ARM64 build
- Inbound: 22, 8000, 8080 (plus 8089 for Log Observer Connect in AW #2)
- Roughly 3 GB of downloads during host setup, mostly Splunk Enterprise

See [`versions.env`](versions.env) for every pinned version. Nothing in this workshop
resolves "latest" at install time — two participants on different days must get
byte-identical software.

## The dashboards

The five capstone dashboards ship as a single installable Splunk app, downloaded once
in FW #2 §12. AW #1 and AW #2 then open dashboards the participant already has.

| Dashboard | Filled in by |
|---|---|
| Foundational Workshop 2 — What You Built | FW #2 |
| Advanced Workshop #1 — Metrics & Traces | AW #1 |
| Advanced Workshop #1 — Infrastructure & Collector Health | AW #1 |
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

`verify-setup.sh`, `verify-fw1.sh`, `verify-fw2.sh`, `verify-aw1.sh` and
`verify-aw2.sh` cover the five modules.

## Repository layout

```
docs/                 the guide (Markdown; also the MkDocs site source)
docs/assets/img/      screenshots, with an inventory + status in manifest.yml
labs/                 real files downloaded during the labs
  collector/            Collector Helm overlays
  dashboards/           the five capstone dashboards (source of truth)
  dashboards/app/       Splunk app skeleton — app.conf, nav, metadata
  dashboards/dist/      built .tgz (build artifact, committed so guides can curl it)
  dockerfiles/          PetClinic container build
  jmeter/               load generation plan
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

Rebuilt from the original v3.0.1 Word guides. Last full fresh-instance run:
**2026-08-21**, all five modules end to end on a clean EC2 host.

| Module | Tested |
|---|---|
| Host setup | ✅ 2026-08-21 |
| FW #1 | ✅ 2026-08-21 |
| FW #2 | ✅ 2026-08-21 |
| AW #1 | ✅ 2026-08-21 |
| AW #2 | ✅ 2026-08-21 |

Known gaps, tracked honestly rather than quietly:

- **Screenshots** carried over from the original Word guides are marked `stale` in
  `docs/assets/img/manifest.yml` and carry a visible banner in the docs until
  re-captured against the current UI. The five dashboard screenshots are `verified`.
- **Concepts pages** have not been fact-checked against current product behaviour.

## Author

Gerry D'Costa — Staff Solutions Engineer, Splunk
