# Troubleshooting

Failures collected from running this workshop end to end. Module-specific problems live at
the bottom of each module page; this covers the cross-cutting ones.

!!! tip "The general principle"
    Most failures in this workshop are **silent**. Configuration renders, pods stay
    healthy, commands exit 0 — and no data moves. When something "doesn't work", resist
    re-running it. Instead, check each hop in turn: does the config contain your change,
    does the component see it, does the data arrive.

---

## Hardened images

Some corporate Ubuntu images are hardened to CIS benchmarks. Most of that is harmless here,
but a few settings will stop the workshop outright.

### `overlay` kernel module blocked

**Symptom:** Docker won't start, reports no storage driver, or minikube fails immediately.

**Test — no privileges needed.** Do this one first. If Docker reports an overlay driver,
the module is loaded and working, and there is nothing to investigate:

```bash
docker info -f '{{.Driver}}'      # want: overlayfs
```

!!! warning "The mount test below must be run as `ubuntu`, not `splunk`"
    The workshop user `splunk` deliberately has no sudo rights (see
    *"`sudo: a password is required` as the splunk user"* below). Run the mount test as
    `splunk` and every `sudo` line fails on **permission**, which reads exactly like the
    module being blocked. It isn't. Open an `ubuntu` session first:

    ```bash
    ssh -i <your-key.pem> ubuntu@<your-instance>
    ```

**Explicit test, as `ubuntu`:**

```bash
sudo mkdir -p /tmp/ov/{l,u,w,m}
sudo mount -t overlay overlay \
  -o lowerdir=/tmp/ov/l,upperdir=/tmp/ov/u,workdir=/tmp/ov/w /tmp/ov/m \
  && echo "✓ overlay OK" && sudo umount /tmp/ov/m
sudo rm -rf /tmp/ov
```

`unknown filesystem type 'overlay'` means it's genuinely blocked. `sudo: a password is
required` means you are still the `splunk` user — that is not a diagnosis. Confirm where
the block lives (also as `ubuntu`):

```bash
sudo grep -rn 'overlay' /etc/modprobe.d/
```

A line like `install overlay /bin/false` hard-blocks the module — `blacklist` alone only
prevents autoloading, but `install … /bin/false` prevents loading entirely.

!!! danger "This is not negotiable — no container runtime works without it"
    Docker's default storage driver is `overlay2`, and minikube's runtime needs the same
    module. If `overlay` cannot load, nothing in this workshop runs.

    Worth raising with whoever owns the image: **`overlay` is not part of the CIS Ubuntu
    benchmark.** CIS calls for blocking `cramfs`, `freevxfs`, `hfs`, `hfsplus`, `jffs2`,
    `squashfs`, `udf` and `usb-storage`. Blocking `overlay` is an addition beyond the
    standard, and it means "no containers on this host".

    Note also that `squashfs` is commonly blocked *and* compiled into the kernel
    (`CONFIG_SQUASHFS=y`), so the block is cosmetic there. `overlay` is usually a module
    (`CONFIG_OVERLAY_FS=m`), so the block is real. Check with:
    ```bash
    grep -E 'CONFIG_OVERLAY_FS|CONFIG_SQUASHFS' /boot/config-$(uname -r)
    ```

If an exception is granted, override without editing the config-managed file — again as
`ubuntu`:

```bash
echo 'install overlay /sbin/modprobe --ignore-install overlay' \
  | sudo tee /etc/modprobe.d/00-docker-overlay.conf
sudo modprobe overlay && lsmod | grep overlay
```

Editing `/etc/modprobe.d/CIS.conf` directly is a bad idea where it carries an
`# ANSIBLE MANAGED BLOCK` marker — a configuration push will revert it, and the workshop
will break again later with no obvious cause.

### IP forwarding disabled

**Symptom:** cluster starts but nothing routes; pods can't reach the host or each other.

```bash
sysctl net.ipv4.ip_forward     # want 1
```

The Docker daemon sets this to `1` at start, so it self-heals on most hosts. On a hardened
image that re-applies `sysctl` on boot, make it explicit:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-k8s-workshop.conf
sudo sysctl --system
```

### `noexec` on `/tmp`

**Symptom:** minikube, Docker builds, or Maven fail with permission errors that don't
mention `/tmp`.

```bash
findmnt -no OPTIONS /tmp | tr ',' '\n' | grep -x noexec
```

minikube extracts and executes helpers from `/tmp`. If `noexec` is set, either request an
exception or point the toolchain elsewhere with `TMPDIR`.

### Shell timeout during long steps

Hardened images often set a readonly `TMOUT` (commonly 900s) in `/etc/profile.d/`. It fires
on an idle prompt, so long-running commands are safe — but reading between steps will log
you out. `tmux` is the fix:

```bash
tmux new -s workshop     # detach with Ctrl-b d, return with: tmux attach -t workshop
```

### Password policy rejects the workshop user

This workshop **sets no password** on the `splunk` account and uses SSH keys, so
`pam_pwquality` rules are not an issue. If you're adapting an older revision of this guide
that set a short shared password, expect it to be rejected outright — hardened images
typically require 14 characters with mixed classes. Use the key-based approach instead.

---

## Silent configuration failures

The hardest class of problem here. Three real examples, all of which report success:

| What you changed | Why nothing happened |
|---|---|
| A `sed` against the chart's `values.yaml` | The anchor string no longer exists in the current chart. `sed` matched nothing, changed nothing, exited 0. |
| An OTTL `transform` processor | Paths weren't context-prefixed, or targeted the wrong attribute context. Config parses, pods stay healthy, no data changes. |
| A pod annotation | Applied to the Deployment's metadata rather than the **pod template**. The pod never gets it. |

**The diagnostic that resolves most of them** — read the configuration the Collector is
actually running, rather than the values you think you supplied:

```bash
kubectl get cm ${WS_USER}-k8s-ws-splunk-otel-collector-otel-agent \
  -o go-template='{{index .data "relay"}}'
```

If your change isn't in there, the overlay didn't apply — check indentation and re-run
`helm upgrade`. If it *is* there and still has no effect, the condition isn't matching.

And to see what a values file will produce *before* installing:

```bash
helm template t splunk-otel-collector-chart/splunk-otel-collector \
  --version 0.158.0 -f values-workshop.yaml
```

---

## Messages that look like errors but aren't

??? note "`received a 410 ... The resourceVersion for the provided watch is too old`"
    Normal. The cluster receiver periodically re-establishes its watch against the
    Kubernetes API and logs this at INFO level. No action needed.

??? note "`The connection to the server localhost:8080 was refused`"
    Expected from `kubectl` before a cluster exists. Harmless during host setup.

??? note "`minikube skips various validations when --force is supplied`"
    Only appears if you pass `--force`. This workshop doesn't need it — running minikube as
    a normal (non-root) user is the supported path.

??? note "`one or more paths were modified to include their context prefix`"
    **This one matters.** It's logged at INFO, but it means your OTTL statements used the
    old bare-path syntax and were silently rewritten. Use `log.attributes[...]` and
    `resource.attributes[...]` explicitly — see FW #2, step 9.

---

## Data that looks wrong but isn't

??? failure "Severity shows UNKNOWN in Log Observer"
    **Check the time picker before you touch the configuration.**

    Severity is written at **ingest**. Any log indexed while the OTTL transform was
    incomplete — that is, everything from before you finished FW #2 step 11 — stays
    `UNKNOWN` **permanently**. Fixing the transform classifies new events; it cannot
    reclassify old ones. Re-running `helm upgrade`, re-reading your OTTL and re-checking
    the Collector config will all produce no change, because nothing about the current
    configuration is wrong.

    Opening Log Observer with a wide or default time window therefore shows a large block of
    UNKNOWN rows on a cluster that is working correctly.

    **The diagnostic that separates "config is wrong" from "data is old"**, in one query:

    ```
    index=k8s_ws_petclinic_logs
    | eval s=if(isnull(severity),"UNKNOWN","classified")
    | timechart span=1h count by s
    ```

    Read the **most recent** buckets, not the totals:

    | What the timechart shows | What it means |
    |---|---|
    | UNKNOWN early, `classified` taking over from one hour onward | Working. You're looking at pre-fix data — narrow the picker to the last 15 minutes. |
    | UNKNOWN in the current hour, `classified` at zero throughout | The transform genuinely isn't classifying. Go back to FW #2 step 11. |

    !!! tip "Narrow the window first"
        Set Log Observer to the last 15 minutes before concluding anything. If severity is
        correct there, the configuration is correct.

    Some UNKNOWN in `k8s_ws_logs` is also expected and not a fault — Kubernetes audit
    records are structured JSON about API calls and have no severity to extract.

---

## Environment and access

??? failure "Commands run, exit 0, and change the wrong thing after a reconnect"
    **The single most common silent failure in this workshop.** `~/.workshop-env` is
    **not** loaded automatically. Every new SSH session, every `tmux` pane, every
    `sudo -i -u splunk` — all start with `WS_USER`, `LOCAL_IP` and `HEC_TOKEN` empty.

    Nothing errors. `${WS_USER}` simply expands to nothing:

    ```bash
    helm upgrade ${WS_USER}-k8s-ws ...     # you typed this
    helm upgrade -k8s-ws ...               # helm received this
    ```

    That is a **different release name**, not a failure. Helm will happily install a second
    release, and your actual Collector is left untouched — so every check you run afterwards
    reports the old configuration and you conclude the change didn't apply.

    **The one-line check, every time you reconnect:**

    ```bash
    echo "$WS_USER on $LOCAL_IP"
    ```

    Empty output — or just the word `on` — means the variables aren't set:

    ```bash
    source ~/.workshop-env
    ```

    !!! tip "Make it stick"
        ```bash
        echo 'source ~/.workshop-env' >> ~/.profile
        ```
        If you already created a stray release from an unset variable, list what actually
        exists with `helm list -A` and `helm uninstall` the wrong one.

??? failure "`sudo: a password is required` as the splunk user"
    By design — `splunk` has no password and no sudo rights. Privileged operations belong
    to the `ubuntu` account and are handled during host setup.

    The one that catches people is the `/etc/hosts` entry for `minikube`. If it's missing,
    add it as `ubuntu`:
    ```bash
    echo -e "192.168.49.2\tminikube" | sudo tee -a /etc/hosts
    ```

??? failure "`curl http://minikube:30000` fails but the IP works"
    Same cause as above — the hosts entry is missing.

??? failure "`docker` says permission denied as the splunk user"
    Group membership isn't active in the current session. Log out and back in, or:
    ```bash
    newgrp docker
    ```

??? failure "Images build but Kubernetes reports ErrImageNeverPull"
    The image went to the host's Docker daemon instead of minikube's. Run
    `eval $(minikube -p minikube docker-env)` **before** building, then confirm with
    `docker images` — the image must appear *after* that eval.

---

## Resource exhaustion

??? failure "Pods evicted, or minikube becomes unresponsive during AW #1/#2"
    By the advanced modules the host is running a Kubernetes cluster, Splunk Enterprise,
    the Collector, PetClinic with a Java agent, and a load generator. 16 GB is
    comfortable; 8 GB is not.

    ```bash
    free -h
    kubectl top nodes
    kubectl top pods
    ```

??? failure "Out of disk"
    The full workshop consumes roughly 25–30 GB. Reclaim space from superseded image
    layers:
    ```bash
    docker system prune -a
    ```
    Splunk indexes also grow — the Kubernetes audit log is deliberately verbose.

---

## Still stuck

Every module ships an assertion script that reports precisely which step failed:

```bash
cd ~/k8s-otel-workshop
source ~/.workshop-env                     # WS_USER, LOCAL_IP, HEC_TOKEN
export SPLUNK_AUTH=admin:'Workshop2026!'   # needed by verify-fw2.sh onward

./scripts/verify-setup.sh     # host
./scripts/verify-fw1.sh       # Foundational #1
./scripts/verify-fw2.sh       # Foundational #2
./scripts/verify-aw1.sh       # Advanced #1
./scripts/verify-aw2.sh       # Advanced #2
```

!!! tip "If a script exits immediately"
    `verify-fw2.sh: line 8: SPLUNK_AUTH: export SPLUNK_AUTH=admin:<password>` means you
    skipped the `export` above. An empty `WS_USER` is the other common cause — see
    *"Commands run, exit 0, and change the wrong thing after a reconnect"*.

    `Workshop2026!` is the workshop's fixed admin password. The single quotes matter: `!`
    is history expansion in an interactive `bash` shell.
