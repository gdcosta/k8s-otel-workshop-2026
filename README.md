# Splunk Kubernetes & OpenTelemetry Workshop

A four-part, hands-on workshop: containerise a Java application, deploy it to
Kubernetes, and observe it with OpenTelemetry into Splunk Enterprise and Splunk
Observability Cloud.

**📖 Read it as a website:** <https://gdcosta.github.io/k8s-otel-workshop/>
(or browse the Markdown in [`docs/`](docs/) — it renders fine on GitHub too)

## The modules

| Module | Time | You will |
|---|---|---|
| [Host setup](docs/00-setup/index.md) | 45 min | Build the Ubuntu host: Docker, minikube, kubectl, Helm, Splunk Enterprise |
| [FW #1](docs/01-foundational-1/index.md) | 1.5 hr | Enable the k8s audit log, build & containerise PetClinic, deploy it |
| [FW #2](docs/02-foundational-2/index.md) | 2 hr | Deploy the OTel Collector, collect logs, annotations, multiline, OTTL transforms |
| [AW #1](docs/03-advanced-1/index.md) | 2 hr | Metrics, JVM auto-instrumentation, traces, index routing, dashboards |
| [AW #2](docs/04-advanced-2/index.md) | 2 hr | Observability Cloud: APM, Log Observer Connect, AlwaysOn Profiling, RUM |

## Requirements

- One EC2 instance per participant: **Ubuntu 24.04 LTS, x86-64**, 4 vCPU / 16 GB, 100 GB gp3
- ARM is not an option — Splunk Enterprise has no Linux ARM64 build
- Inbound: 22, 8000, 8080 (plus 8089 for Log Observer Connect in AW #2)
- Roughly 3 GB of downloads during host setup, mostly Splunk Enterprise

See [`versions.env`](versions.env) for every pinned version.

## Verifying your progress

Each module ships an assertion script. They're also what the CI canary runs against new
Collector chart releases.

```bash
export WS_USER=<your-username>
./scripts/verify-fw1.sh
```

## Repository layout

```
docs/          the guide (Markdown; also the MkDocs site source)
labs/          real files you download during the labs — manifests, values, Dockerfiles
scripts/       bootstrap, per-module fast-forward, and verification scripts
assets/img/    screenshots
versions.env   every pinned version, in one place
```

## Building the site locally

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install mkdocs-material
mkdocs serve      # http://127.0.0.1:8000
```

## Status

Rebuilt from the original v3.0.1 Word guides. Every command is tested end to end on a
live EC2 instance rather than transcribed — see [`CHANGELOG.md`](CHANGELOG.md) for what
changed and why.

| Module | Tested |
|---|---|
| Host setup | ✅ 2026-08-18 |
| FW #1 | ✅ 2026-08-18 |
| FW #2 | ✅ 2026-08-18 |
| AW #1 | ⏳ in progress |
| AW #2 | ⏳ pending |

Screenshots carry a visible banner until re-captured against current UI.

## Author

Gerry D'Costa — Staff Solutions Engineer, Splunk
