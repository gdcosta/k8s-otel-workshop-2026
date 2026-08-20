# Host setup

**Duration:** ~45 minutes, most of it downloads · **Run once**, before Foundational
Workshop #1

This builds the machine everything else runs on: container runtime, a Kubernetes
toolchain, and a local Splunk Enterprise instance.

!!! tip "There is a script for all of this"
    If you just want a working host, skip to [Automated setup](#automated-setup) and run
    `bootstrap.sh`. Work through the manual steps if you want to understand what the host
    actually needs — the workshop assumes no prior Kubernetes experience, and the pieces
    installed here get referenced throughout.

---

## Before you start

### Instance requirements

| | |
|---|---|
| **OS** | Ubuntu 24.04 LTS |
| **Architecture** | **x86-64 / amd64** |
| **Size** | 4 vCPU, 16 GB RAM (AWS `t3.xlarge` or equivalent) |
| **Disk** | 100 GB |
| **Access** | SSH key pair — no password authentication |

!!! info "Where `<your-key.pem>` comes from"
    Every command in this workshop that reaches the instance uses a private key file,
    written throughout as `<your-key.pem>`. Substitute your own path. Which case you are in
    depends on how you got your instance:

    | | You have | Do this |
    |---|---|---|
    | **A facilitator built it for you** | a `.pem` they sent you | save it somewhere private, then `chmod 400` it |
    | **You gave them a public key** | your own existing private key | use it as-is — nothing new to save |
    | **You are building your own** | whatever you create at launch | AWS offers a key pair in the launch wizard; download the `.pem` and keep it |

    If a facilitator asks for a **public** key rather than sending you a private one, that
    is the better arrangement — your private key never travels. Generate a pair with
    `ssh-keygen -t ed25519` and send them only the `.pub` file.

    You need this before step 1. There is no password login — that is deliberate, and
    covered in step 5.

!!! danger "ARM will not work"
    Splunk Enterprise has **no Linux ARM64 build**. Splunk's own documentation states
    *"The ARM architecture is not supported for use with Splunk Enterprise at this time"* —
    ARM64 exists only for the Universal Forwarder.

    Everything else in this workshop runs on ARM quite happily, but Splunk Enterprise runs
    natively on this host and is central to FW #2 and AW #1. Use x86-64.

!!! warning "You will download about 3 GB"
    Splunk Enterprise alone is **1.6 GB**, and minikube pulls a ~520 MB base image. Don't
    start this on a constrained or metered connection.

### Network access

Inbound, from your own IP — never `0.0.0.0/0`:

| Port | Purpose |
|---|---|
| 22 | SSH — and every browser tunnel this workshop uses |
| 8000 | Splunk Web |
| 8080 | *Optional* — only if you publish PetClinic on the host instead of tunnelling |
| 8089 | *Advanced Workshop #2 only* — Log Observer Connect |

!!! tip "Reaching PetClinic from your laptop needs **no extra port**"
    The application listens on NodePort **30000**, but that port is bound to **minikube's
    internal address** (`192.168.49.2`), not to the instance's own interfaces. Verified on a
    running host:

    ```
    ss -ltn | grep 30000     ->  nothing. 30000 is not bound on the host at all.
    curl http://192.168.49.2:30000/   ->  200   (works from the host only)
    ```

    So **opening 30000 in the security group accomplishes nothing** — there is no listener
    on the public interface for the rule to expose. It is the obvious guess and it is wrong.

    The SSH tunnel below reaches it over port **22**, which is already open. That is why
    this workshop needs no additional inbound rule for the application.

??? warning "If you really want PetClinic exposed directly, without a tunnel"
    Two things are both required — either alone does nothing:

    1. Publish it on the host's public interface. `kubectl port-forward` binds
       **loopback only** by default (`127.0.0.1:8080`), so it must be given an address:

        ```bash
        kubectl port-forward --address 0.0.0.0 svc/${WS_USER}-petclinic-srv 8080:8080
        ```

        Verified: with `--address 0.0.0.0` it binds `0.0.0.0:8080` and answers `200` on the
        instance's private IP; without it, nothing outside the host can connect.

    2. Open **8080** inbound **to your own IP** in the security group.

    Confirmed with step 1 running but 8080 still closed, from outside AWS: connection
    refused. The security-group rule is the remaining gate.

    Prefer the tunnel. It needs no rule, exposes nothing to the internet, and dies with your
    SSH session rather than outliving it.

Outbound: all. The host pulls from GitHub, Docker Hub, the Ubuntu archives, Splunk, and —
in AW #2 — Splunk Observability Cloud.

!!! danger "Port 8000 must be scoped to your own address"
    This workshop uses fixed credentials that are printed in the guide — `admin` /
    `Workshop2026!` — so every later command is copy-pasteable and an facilitator can sign in
    to help someone who is stuck. That is only safe while the login page is not open to the
    internet: an EC2 host name is predictable, and the password is on this page.

    Restrict the port 8000 rule to your own IP. If you would rather not open it at all,
    leave it closed and reach Splunk Web through the SSH tunnel in the next section.

    These are throwaway credentials on a disposable instance. Never reuse them — or this
    practice — on anything real.

---

## Connect to your instance

You have a host name and an SSH key file. Everything from here happens over SSH.

=== "macOS / Linux"

    ```bash
    chmod 400 <your-key.pem>
    ssh -i <your-key.pem> ubuntu@<your-instance>
    ```

=== "Windows"

    ```powershell
    icacls <your-key.pem> /inheritance:r /grant:r "$($env:USERNAME):R"
    ssh -i <your-key.pem> ubuntu@<your-instance>
    ```

    PowerShell and Windows Terminal ship OpenSSH, `ssh -L` included. Nothing else — no
    PuTTY, no extra tooling — is needed for anything in this workshop.

!!! warning "`WARNING: UNPROTECTED PRIVATE KEY FILE`"
    OpenSSH refuses a private key other users can read, and the error names the file rather
    than the fix: `chmod 400 <your-key.pem>`. A key straight out of a browser download
    almost always needs it.

### Two accounts

Host setup runs as **`ubuntu`**, the administrative account — it installs packages, edits
`/etc/hosts`, and creates the workshop user. Everything after this page runs as
**`splunk`**: the cluster, the application, and Splunk Enterprise all live under that
account, which has no password and no sudo, deliberately.

```bash
sudo -i -u splunk      # from the ubuntu session, at any time
```

Step 5 copies your public key into the `splunk` account. After that you can connect
straight to it, which is how you open the second terminal FW #2 asks for:

```bash
ssh -i <your-key.pem> splunk@<your-instance>
```

### Browser access, and the one thing that needs a tunnel

Two web UIs matter here, and only one of them is reachable directly:

| | Runs on | Listens on | From your laptop |
|---|---|---|---|
| Splunk Web `:8000` | the EC2 host | `0.0.0.0:8000` | direct, once your IP is allowed |
| PetClinic `:30000` | inside Kubernetes | NodePort on `192.168.49.2` | **not reachable** — tunnel it |

`192.168.49.2` is minikube's address on a Docker network *inside* the host. It isn't
routable from anywhere else, so no security-group rule can expose it — opening ports simply
does nothing. FW #1 explains what a NodePort is; this is the practical consequence.

Forward it when you connect and it costs you nothing:

```bash
# PetClinic → http://localhost:8080 in your browser
ssh -i <your-key.pem> -L 8080:192.168.49.2:30000 splunk@<your-instance>
```

!!! abstract "Learning moment — what `-L` actually does"
    This is **SSH local port forwarding**, and it is worth understanding rather than
    copying, because it is the mechanism behind every browser step in this workshop.

    ```
    -L  8080  :  192.168.49.2  :  30000
        ^^^^     ^^^^^^^^^^^^     ^^^^^
        │        │                └─ port there
        │        └─ host, as seen FROM THE INSTANCE
        └─ port on YOUR LAPTOP — the only part you choose
    ```

    Your browser connects to `localhost:8080` on your own machine. SSH carries that traffic
    down the existing connection, and the instance opens the far side **on your behalf** —
    so the target is resolved from *its* network, not yours. That is why `192.168.49.2`
    works here and nowhere else.

    Three consequences worth drawing out:

    - **No security-group rule is involved.** The traffic is inside the SSH session on port
      22, which is already open. There is nothing new listening on the instance and nothing
      new exposed to the internet.
    - **It needs no `kubectl` and leaves nothing running.** The forward exists only while
      that SSH session does, and dies with it.
    - **Only the left-hand number is yours.** Everything right of the first colon is
      interpreted on the instance. If 8080 is busy on your laptop, change *that* number —
      `-L 8081:192.168.49.2:30000` — and browse `localhost:8081` instead.

    The same trick reaches anything the instance can see: `-L 8000:localhost:8000` for
    Splunk Web, where `localhost` means *the instance's* localhost.

```bash
# the same, plus Splunk Web on http://localhost:8000 if you left 8000 closed
ssh -i <your-key.pem> \
  -L 8080:192.168.49.2:30000 \
  -L 8000:localhost:8000 \
  splunk@<your-instance>
```

!!! note "Nothing answers on 8080 until FW #1"
    The tunnel is only useful once PetClinic is deployed. Until then `http://localhost:8080`
    refuses the connection — that's expected, not a broken tunnel. Until step 5 has run,
    connect as `ubuntu@` instead; the forwarding flags are identical.

---

## Automated setup

```bash
git clone https://github.com/gdcosta/k8s-otel-workshop-2026.git ~/k8s-otel-workshop
cd ~/k8s-otel-workshop
./scripts/bootstrap.sh
```

It's idempotent — safe to re-run if something fails partway. It reads every version from
[`versions.env`](https://github.com/gdcosta/k8s-otel-workshop-2026/blob/main/versions.env), so
that file is the single place to change a pin.

The verification scripts run as `splunk`, so that account needs its own copy of the repo:

```bash
sudo -u splunk git clone https://github.com/gdcosta/k8s-otel-workshop-2026.git \
  /home/splunk/k8s-otel-workshop
```

Then set your username — the script leaves it as `CHANGE_ME`:

```bash
WS_USER=wsuser01     # ← your own, lowercase, no spaces
sudo sed -i "s/^export WS_USER=.*/export WS_USER=${WS_USER}/" /home/splunk/.workshop-env
```

Confirm the variables reach a fresh login shell:

```bash
sudo -i -u splunk
echo "$WS_USER on $LOCAL_IP ($PUB_DNS)"
```

Empty output means `.profile` isn't loading the file — apply
[step 13](#13-set-up-the-splunk-shell-environment) by hand.

When that reads back correctly, jump to [Verify the host](#verify-the-host).

---

## Manual setup

Everything in this section runs as the **`ubuntu`** user — the administrative account you
connected as above. The workshop itself runs as a separate `splunk` user, created in step 5.

### 1. Update the system

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
```

### 2. Install base packages

```bash
sudo apt-get install -y \
  curl wget net-tools unzip jq git \
  ca-certificates gnupg apt-transport-https \
  python3-venv \
  ne
```

`python3-venv` is needed by Advanced Workshop #2 — Ubuntu 24.04 ships Python without it,
and `python3 -m venv` fails with `ensurepip is not available` until it's installed.

`ne` ("nice editor") is a friendlier alternative to `vi` if you'd rather not use `vi`
during the labs.

### 3. Install Java

```bash
sudo apt-get install -y openjdk-21-jdk
java -version
```

!!! note "PetClinic targets Java 17, and builds fine on 21"
    The project's `pom.xml` declares `<java.version>17</java.version>`, but it compiles and
    runs cleanly under JDK 21. In FW #1 you'll set `JAVA_HOME` explicitly rather than rely
    on whatever the system default happens to be — installing multiple JDKs silently
    changes that default, which is exactly the kind of drift that makes a build
    irreproducible.

### 4. Install Docker

```bash
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
docker --version
sudo docker info -f '{{.Driver}}'
```

<details>
<summary>Expected output</summary>

```
Docker version 29.1.3, build 29.1.3-0ubuntu3~24.04.2
overlayfs
```

The storage driver matters. Docker needs the `overlay` kernel module; on a hardened image
where that module is blocked, Docker cannot start. See
[Troubleshooting](../troubleshooting.md#hardened-images).
</details>

!!! note "IP forwarding sorts itself out"
    Ubuntu ships with `net.ipv4.ip_forward=0`, which would break container networking. The
    Docker daemon sets it to `1` when it starts, so no manual `sysctl` change is needed on
    a stock image. On a hardened host that re-applies sysctl settings on boot, check this
    after a reboot.

### 5. Create the `splunk` user

The workshop runs as a dedicated user. Kubernetes state, the application build, and
Splunk Enterprise all live under this account.

```bash
sudo useradd -s /bin/bash -d /home/splunk -m splunk
sudo groupadd -f docker
sudo usermod -aG docker splunk
sudo usermod -aG docker ubuntu
id splunk
```

!!! danger "`-aG`, never `-g`"
    `usermod -g docker splunk` **replaces** the user's primary group, leaving `splunk`
    without a personal group and producing surprising file ownership later. `-aG`
    *appends* — the user keeps its own group and gains Docker access:

    ```
    uid=1002(splunk) gid=1005(splunk) groups=1005(splunk),114(docker)
    ```

Give `splunk` the same SSH key you're using, so you can open a second terminal directly as
that user:

```bash
sudo mkdir -p /home/splunk/.ssh
sudo cp ~/.ssh/authorized_keys /home/splunk/.ssh/authorized_keys
sudo chown -R splunk:splunk /home/splunk/.ssh
sudo chmod 700 /home/splunk/.ssh
sudo chmod 600 /home/splunk/.ssh/authorized_keys
```

!!! info "No password is set, deliberately"
    Earlier versions of this workshop set a shared password on `splunk` and re-enabled
    `PasswordAuthentication` in `sshd_config`. That put a publicly-reachable host on the
    internet with a known credential, and it fails outright on hardened images whose
    password policy rejects short passwords.

    Key-based access replaces it. You reach the account two ways:

    ```bash
    ssh -i <your-key.pem> splunk@<HOST>   # directly, from your laptop
    sudo -i -u splunk                     # from the ubuntu account
    ```

### 6. Clone the workshop repository

Every module ends with a `verify-*.sh` script from this repository, and they all run as
`splunk` — so clone it into that account's home, not `ubuntu`'s:

```bash
sudo -u splunk git clone https://github.com/gdcosta/k8s-otel-workshop-2026.git \
  /home/splunk/k8s-otel-workshop
sudo -u splunk ls /home/splunk/k8s-otel-workshop/scripts
```

The repo also carries the lab files later modules download — manifests, Collector values,
JMeter plans — so you have a local copy of each if a download ever fails.

### 7. Add the minikube hostname

```bash
echo -e "192.168.49.2\tminikube" | sudo tee -a /etc/hosts
getent hosts minikube
```

!!! warning "Do this now, as `ubuntu` — it is the trap in this workshop"
    Later steps reach the application at `http://minikube:30000`, so this entry has to
    exist. It needs root, and **the `splunk` user cannot use `sudo`** — it's not in a
    NOPASSWD group, and password authentication is disabled.

    The failure is silent. A command like `... | sudo tee -a /etc/hosts >/dev/null` sends
    sudo's error to `/dev/null`, returns exit code 0, and writes nothing. You then get
    connection failures in FW #1 that point nowhere near the real cause.

    The address is fixed because FW #1 starts minikube with `--subnet=192.168.49.0/24`.

### 8. Install kubectl

```bash
KUBECTL_VERSION=v1.36.3
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
sudo install -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl
kubectl version --client -o json | jq -r .clientVersion.gitVersion
```

!!! danger "Pin it — don't resolve `stable.txt`"
    The common install snippet fetches `stable.txt` and installs whatever it names. Two
    people running the workshop a week apart then get different clients, and a workshop
    that can't be reproduced can't be supported. Pin the version.

### 9. Install minikube

```bash
MINIKUBE_VERSION=v1.38.1
curl -fsSLO "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64"
sudo install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube
rm minikube-linux-amd64
minikube version
```

### 10. Install Helm

```bash
HELM_VERSION=v4.2.4
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
rm -rf linux-amd64 "helm-${HELM_VERSION}-linux-amd64.tar.gz"
helm version --short
```

!!! warning "Not the apt repository"
    Most Helm install guides add the `baltocdn.com` apt repository. **That host currently
    fails TLS certificate validation** against an up-to-date CA bundle:

    ```
    TLS alert, unknown CA (560)
    SSL certificate problem: unable to get local issuer certificate
    ```

    The pinned tarball from `get.helm.sh` is the official distribution, avoids the apt-key
    and keyring dance entirely, and pins the version explicitly — which is what a
    reproducible workshop wants anyway.

Helm 4 is used deliberately: the Splunk OTel Collector chart requires *"Helm 3.9+ or
Helm 4.x"* and is tested against both.

### 11. Create the workshop environment file

Every later module refers to the same handful of values. Put them in one file so any shell
— including the second terminal you'll open for load testing — can load them in one command.

```bash
sudo -u splunk tee /home/splunk/.workshop-env >/dev/null <<'EOF'
# Workshop session variables. Loaded automatically by ~/.profile (step 13).
# In a shell that hasn't loaded it:  source ~/.workshop-env

# Your username. Prefixes every resource you create so attendees sharing a
# Splunk or Observability Cloud environment don't collide.
export WS_USER=CHANGE_ME

# This instance's private IP — what the Collector uses to reach Splunk's HEC.
export LOCAL_IP=$(ec2metadata --local-ipv4 2>/dev/null || hostname -I | awk '{print $1}')

# The public DNS name — what you point a browser at, and what Log Observer
# Connect uses to reach this instance in AW #2.
export PUB_DNS=$(ec2metadata --public-hostname 2>/dev/null || curl -s ifconfig.me)

# Pinned versions, so commands can be copied without editing.
export CHART_VERSION=0.158.0
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64

# Filled in as you go:
#   HEC_TOKEN      — Foundational Workshop #2, step 3
#   O11Y_REALM     — Advanced Workshop #2, step 1
EOF

sudo chown splunk:splunk /home/splunk/.workshop-env
sudo chmod 600 /home/splunk/.workshop-env
```

Set your username. Do it from the `ubuntu` session — the remaining steps still need root:

```bash
WS_USER=wsuser01      # ← your own, lowercase, no spaces
sudo sed -i "s/^export WS_USER=.*/export WS_USER=${WS_USER}/" /home/splunk/.workshop-env
sudo -u splunk grep '^export WS_USER' /home/splunk/.workshop-env
```

!!! note "Why the file comes before the Splunk install"
    The next step ends with the Splunk Web URL, which is `$PUB_DNS` — defined here. An
    earlier revision created this file *afterwards*, and the URL printed as `http://:8000`.
    Step 12 itself runs in the `ubuntu` shell, which never loads this file, so it asks the
    instance metadata service for the same value directly.

    The quoted heredoc (`<<'EOF'`) is deliberate: `$(ec2metadata ...)` stays literal in the
    file and is evaluated each time the file is sourced, so the values are right even if the
    instance is stopped and started with a new public address.

### 12. Install Splunk Enterprise

```bash
SPLUNK_VERSION=10.4.2
SPLUNK_HASH=33c3bf42cd73
cd ~/
wget -O splunk.tgz \
  "https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/splunk-${SPLUNK_VERSION}-${SPLUNK_HASH}-linux-amd64.tgz"
sudo tar -xzf splunk.tgz -C /opt
sudo chown -R splunk:splunk /opt/splunk
rm splunk.tgz
```

Seed the admin account with the workshop's standard credentials:

```bash
sudo -u splunk tee /opt/splunk/etc/system/local/user-seed.conf >/dev/null <<'EOF'
[user_info]
USERNAME = admin
PASSWORD = Workshop2026!
EOF

sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt
sudo -u splunk /opt/splunk/bin/splunk version
```

!!! warning "Published credentials — two things follow, neither optional"
    `admin` / `Workshop2026!` is the same on every participant's instance and is printed in
    this guide, so every later command is copy-pasteable and an facilitator can sign in to
    help. Because of that:

    - **Port 8000 must be restricted to your own IP** in the security group. A published
      password on an internet-facing login page is an open door, and these hosts have
      predictable names. If you would rather not open it at all, close 8000 and use the SSH
      tunnel from [Connect to your instance](#browser-access-and-the-one-thing-that-needs-a-tunnel).
    - **These are throwaway lab credentials on a disposable instance.** Never reuse them, or
      this practice, on anything real. AW #2 adds a second fixed account —
      `loc_svc` / `LogObserver2026!` — on exactly the same terms.

Splunk Web is now up on port 8000. From this `ubuntu` shell:

```bash
echo "http://$(ec2metadata --public-hostname):8000"
```

In the `splunk` account that same value is `$PUB_DNS`, from the file you created in step 11.

!!! note "Splunk 10.4 is a major jump from earlier versions of this workshop"
    Previous revisions pinned 9.0.4.1, which is long past end of support. Aside from being
    a much larger download, one behavioural change matters directly: **HEC now enables SSL
    by default.** FW #2 covers that at the point where it bites.

### 13. Set up the `splunk` shell environment

Two things belong in that account's `.profile`: the workshop variables, and the pointer at
minikube's Docker daemon.

```bash
sudo -u splunk tee -a /home/splunk/.profile >/dev/null <<'EOF'

# k8s workshop — load the session variables in every login shell
[ -f ~/.workshop-env ] && . ~/.workshop-env

# k8s workshop — point docker at minikube's daemon
if command -v minikube >/dev/null && minikube status >/dev/null 2>&1; then
  eval "$(minikube -p minikube docker-env)"
fi
EOF
```

The first block is what makes `${WS_USER}` work in every terminal, including one you open a
week later; tokens added to the file by later modules are picked up at the next login. The
second makes `docker build` place images inside minikube's image store, where Kubernetes can
find them without a registry — FW #1 explains why that matters.

Check it in a genuinely fresh login shell:

```bash
sudo -i -u splunk
echo "$WS_USER on $LOCAL_IP ($PUB_DNS)"
```

!!! warning "Empty output is the failure you will actually hit"
    If that prints ` on  ()`, the variables aren't loaded. `source ~/.workshop-env` fixes the
    shell you're in; then check the `.profile` lines above really landed.

    Nothing errors when they're missing, which is what makes it expensive:
    `helm upgrade ${WS_USER}-k8s-ws ...` quietly becomes `helm upgrade -k8s-ws ...` — a
    different release name, not a failure. Run that `echo` after every reconnect.

---

## Verify the host

```bash
sudo -i -u splunk
~/k8s-otel-workshop/scripts/verify-setup.sh
```

That's the repository cloned in step 6. `No such file or directory` means the clone landed
in `ubuntu`'s home instead of `splunk`'s — re-run the clone from step 6.

<details>
<summary>What it checks</summary>

1. Ubuntu 24.04, x86-64
2. `docker` running, with a working storage driver
3. `overlay` filesystem usable (the one thing hardened images tend to block)
4. `minikube`, `kubectl`, `helm` present at pinned versions
5. `splunk` user exists, is in the `docker` group, and has an authorized key
6. `minikube` resolves via `/etc/hosts`
7. Splunk Enterprise installed and startable
8. Enough free disk
</details>

---

## Troubleshooting

??? failure "`docker info` reports no storage driver, or Docker won't start"
    The `overlay` kernel module is unavailable. Confirm:
    ```bash
    sudo mkdir -p /tmp/ov/{l,u,w,m}
    sudo mount -t overlay overlay \
      -o lowerdir=/tmp/ov/l,upperdir=/tmp/ov/u,workdir=/tmp/ov/w /tmp/ov/m \
      && echo OK && sudo umount /tmp/ov/m
    sudo rm -rf /tmp/ov
    ```
    `unknown filesystem type 'overlay'` means it's blocked — check
    `/etc/modprobe.d/` for `install overlay /bin/false`. This appears on some hardened
    images and prevents *any* container runtime from working. See
    [Troubleshooting → hardened images](../troubleshooting.md#hardened-images).

??? failure "`helm` install fails with an SSL certificate error"
    You're using the `baltocdn.com` apt repository. Use the `get.helm.sh` tarball in
    step 10 instead.

??? failure "`sudo: a password is required` as the splunk user"
    Expected — `splunk` has no sudo rights and no password. Privileged steps belong to the
    `ubuntu` account. If you hit this mid-lab, something that should have happened during
    setup didn't; `/etc/hosts` in step 7 is the usual culprit.

??? failure "Splunk won't start / port 8000 refused"
    ```bash
    sudo -u splunk /opt/splunk/bin/splunk status
    sudo tail -50 /opt/splunk/var/log/splunk/splunkd.log
    ```
    Ownership is the common cause — `/opt/splunk` must be owned by `splunk`:
    ```bash
    sudo chown -R splunk:splunk /opt/splunk
    ```

??? failure "Out of disk"
    The full workshop uses roughly 30–35 GB: Splunk plus its indexes, minikube's images,
    the Maven cache, several PetClinic image builds, and — in AW #2 — Playwright's
    Chromium download at about 650 MB. 100 GB gives comfortable room to
    rebuild repeatedly. `docker system prune` reclaims space from old image layers.

---

**Next:** [Foundational Workshop #1 — Containers and Kubernetes](../01-foundational-1/index.md)
