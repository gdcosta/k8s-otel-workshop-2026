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
- **FW #2, AW #1, and AW #2 have NOT been touched yet.** They still reference the old
  single-pod Deployment name (`${WS_USER}-petclinic-otel-deployment`) and container name
  (`${WS_USER}-petclinic-otel-container01`) throughout — in the Collector's OTTL
  predicates, the dashboards, JMeter, and the RUM script. **Do not run FW #1 through to
  FW #2 on a live instance right now and expect it to work** — that inconsistency is
  expected mid-migration, not a bug to chase.
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
- Remaining phases (Collector rework, load-generator rewrite, AW1/AW2, dashboards,
  Cilium) are unstarted. See the migration plan for the full phase breakdown and gates.

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
