# Splunk Kubernetes & OpenTelemetry Workshop

A four-part hands-on workshop. You'll containerise a Java application, deploy it to
Kubernetes, and observe it end to end with OpenTelemetry — into Splunk Enterprise first,
then Splunk Observability Cloud.

Every command here is tested on a live instance rather than transcribed.

## Start here

| Module | Time | What you'll do |
|---|---|---|
| [Host setup](00-setup/index.md) | 45 min | Docker, minikube, kubectl, Helm, Splunk Enterprise |
| [FW #1](01-foundational-1/index.md) | 1.5 hr | Audit log, build & containerise PetClinic, deploy |
| [FW #2](02-foundational-2/index.md) | 2 hr | OTel Collector, logs, annotations, multiline, OTTL |
| [AW #1](03-advanced-1/index.md) | 2 hr | Metrics, traces, auto-instrumentation, dashboards |
| [AW #2](04-advanced-2/index.md) | 2 hr | Observability Cloud, APM, profiling, RUM |

Each module ends with a script that asserts you finished it correctly.

## Requirements

Ubuntu 24.04 LTS **x86-64**, 8 vCPU / 32 GB / 100 GB. ARM is not supported — Splunk
Enterprise has no Linux ARM64 build.
