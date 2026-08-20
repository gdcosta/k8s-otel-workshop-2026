#!/usr/bin/env bash
# Builds the workshop host from a blank Ubuntu 24.04 x86-64 instance.
# Run as the `ubuntu` (admin) user. Idempotent — safe to re-run.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_SRC=$PWD                 # this checkout — copied to the splunk account below
source ./versions.env

export DEBIAN_FRONTEND=noninteractive

# --- Fixed workshop credentials ----------------------------------------------
# These are deliberately NOT random. They are published in the guide.
#
# Generating a password per instance bought nothing on a disposable lab box and
# cost a great deal: FW2 §2, FW2 §3, AW2 §4 and verify-fw2.sh all had to carry a
# <YOUR_ADMIN_PASSWORD> placeholder instead of a copy-pasteable command, an
# instructor could not help a stuck participant without asking them to read the
# password out, and anyone who lost the note was locked out of their own
# instance mid-module with no recovery path documented anywhere.
#
# THROWAWAY LAB CREDENTIALS. This instance is disposable and is destroyed at the
# end of the workshop. Never reuse these values, or this pattern, anywhere real.
#
# Because the password is published, Splunk Web must NOT be left open to the
# world: restrict port 8000 in the security group to the participant's own IP
# (the guide does the same for 8089, which is opened only to the Observability
# Cloud realm addresses). The alternative is to keep 8000 closed and reach
# Splunk Web over an SSH tunnel:  ssh -L 8000:localhost:8000 ...
SPLUNK_ADMIN_USER="admin"
SPLUNK_ADMIN_PASSWORD='Workshop2026!'
# Created by the participant in AW2 §4, not here — the guided setup is the
# teaching. Stated here so one place holds both lab credentials.
LOC_SVC_USER="loc_svc"
LOC_SVC_PASSWORD='LogObserver2026!'

step(){ printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
no(){   printf '  \033[31m✗\033[0m %s\n' "$1"; }
have(){ command -v "$1" >/dev/null 2>&1; }

[ "$(id -un)" = "root" ] && { no "run as ubuntu, not root"; exit 1; }
[ "$(dpkg --print-architecture)" = "amd64" ] || { no "amd64 required — Splunk Enterprise has no ARM64 Linux build"; exit 1; }

step "System packages"
sudo apt-get update -qq
sudo apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
sudo apt-get install -y -qq curl wget net-tools unzip jq git \
  ca-certificates gnupg apt-transport-https ne python3-venv \
  "openjdk-${JDK_VERSION}-jdk"
ok "base packages + JDK ${JDK_VERSION}"

step "Docker"
have docker || sudo apt-get install -y -qq docker.io
sudo systemctl enable --now docker >/dev/null 2>&1
sleep 2
if sudo docker info >/dev/null 2>&1; then
  ok "docker $(docker --version | awk '{print $3}' | tr -d ,) — storage driver: $(sudo docker info -f '{{.Driver}}')"
else
  no "docker daemon not running — is the 'overlay' kernel module available?"; exit 1
fi

step "splunk user"
id splunk >/dev/null 2>&1 || sudo useradd -s /bin/bash -d /home/splunk -m splunk
sudo groupadd -f docker
sudo usermod -aG docker splunk          # -aG appends; -g would replace the primary group
sudo usermod -aG docker ubuntu
if [ -f ~/.ssh/authorized_keys ]; then
  sudo mkdir -p /home/splunk/.ssh
  sudo cp ~/.ssh/authorized_keys /home/splunk/.ssh/authorized_keys
  sudo chown -R splunk:splunk /home/splunk/.ssh
  sudo chmod 700 /home/splunk/.ssh; sudo chmod 600 /home/splunk/.ssh/authorized_keys
  ok "splunk user ready, SSH key copied (no password set, by design)"
else
  ok "splunk user ready — no authorized_keys found to copy; use 'sudo -i -u splunk'"
fi

step "workshop repository for the splunk user"
# F3: every module ends with `~/k8s-otel-workshop/scripts/verify-*.sh` run AS
# SPLUNK. Cloning only into ubuntu's home leaves all five checkpoints failing
# with "No such file or directory". Must come after the splunk user exists.
#
# Clones the same URL the manual path uses, so both produce one machine. If the
# clone fails — no network, or the repo not published yet — it falls back to
# copying this checkout, which is byte-identical to what is running right now.
SPLUNK_REPO=/home/splunk/k8s-otel-workshop
WORKSHOP_REPO_URL="${WORKSHOP_REPO_URL:-https://github.com/gdcosta/k8s-otel-workshop-2026.git}"
if [ "$REPO_SRC" = "$SPLUNK_REPO" ]; then
  ok "already running from $SPLUNK_REPO"
elif [ -d "$SPLUNK_REPO/.git" ]; then
  # Idempotent re-run: fast-forward only, so local edits are never discarded.
  if sudo -u splunk git -C "$SPLUNK_REPO" pull --ff-only >/dev/null 2>&1; then
    ok "$SPLUNK_REPO updated (git pull --ff-only)"
  else
    ok "$SPLUNK_REPO present — left as is (no fast-forward available)"
  fi
elif [ -d "$SPLUNK_REPO" ]; then
  ok "$SPLUNK_REPO already present (not a git checkout — left as is)"
elif sudo -u splunk git clone --quiet "$WORKSHOP_REPO_URL" "$SPLUNK_REPO" 2>/dev/null; then
  ok "repo cloned to $SPLUNK_REPO (owned splunk:splunk)"
else
  sudo cp -a "$REPO_SRC" "$SPLUNK_REPO"
  sudo chown -R splunk:splunk "$SPLUNK_REPO"
  ok "clone unavailable — copied this checkout to $SPLUNK_REPO instead"
fi
[ -x "$SPLUNK_REPO/scripts/verify-setup.sh" ] \
  || no "$SPLUNK_REPO/scripts/verify-setup.sh missing — the module checkpoints will not run"

step "minikube hostname"
# Fixed because FW1 starts minikube with --subnet=192.168.49.0/24.
# MUST be done here as ubuntu: the splunk user has no sudo, and the failure is silent.
grep -qP "\tminikube$" /etc/hosts || echo -e "192.168.49.2\tminikube" | sudo tee -a /etc/hosts >/dev/null
getent hosts minikube >/dev/null && ok "minikube -> $(getent hosts minikube | awk '{print $1}')" || no "hosts entry failed"

step "kubectl ${KUBECTL_VERSION}"
if [ "$(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion)" != "$KUBECTL_VERSION" ]; then
  curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
fi
ok "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)"

step "minikube ${MINIKUBE_VERSION}"
# NOTE: `cmd | grep -q` is avoided here. grep -q exits at the first match, the
# producer can then die of SIGPIPE (141), and `pipefail` (set above) reports the
# whole pipeline as failed — so a correctly installed tool looks missing.
mk_have=$(minikube version 2>/dev/null)
case "$mk_have" in *"${MINIKUBE_VERSION#v}"*) mk_ok=1 ;; *) mk_ok=0 ;; esac
if [ "$mk_ok" -eq 0 ]; then
  curl -fsSLO "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64"
  sudo install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube && rm -f minikube-linux-amd64
fi
ok "$(minikube version | head -1)"

step "helm ${HELM_VERSION}"
# get.helm.sh, NOT the baltocdn apt repo — that host fails TLS validation.
helm_have=$(helm version --short 2>/dev/null)
case "$helm_have" in *"${HELM_VERSION}"*) helm_ok=1 ;; *) helm_ok=0 ;; esac
if [ "$helm_ok" -eq 0 ]; then
  curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
  sudo install -m 0755 linux-amd64/helm /usr/local/bin/helm
  rm -rf linux-amd64 "helm-${HELM_VERSION}-linux-amd64.tar.gz"
fi
ok "helm $(helm version --short)"

step "Splunk Enterprise ${SPLUNK_VERSION}  (~1.6 GB)"
if [ ! -x /opt/splunk/bin/splunk ]; then
  wget -q --show-progress -O /tmp/splunk.tgz \
    "https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/${SPLUNK_TGZ}"
  sudo tar -xzf /tmp/splunk.tgz -C /opt && rm -f /tmp/splunk.tgz
  sudo chown -R splunk:splunk /opt/splunk

  # user-seed.conf is consumed on Splunk's FIRST start only. Re-running this
  # script against an existing /opt/splunk therefore changes nothing — reset a
  # forgotten password with:  /opt/splunk/bin/splunk edit user admin ...
  sudo -u splunk tee /opt/splunk/etc/system/local/user-seed.conf >/dev/null <<EOF
[user_info]
USERNAME = ${SPLUNK_ADMIN_USER}
PASSWORD = ${SPLUNK_ADMIN_PASSWORD}
EOF
  sudo chmod 600 /opt/splunk/etc/system/local/user-seed.conf
  ok "installed — admin password seeded from the fixed workshop credential"
else
  ok "already installed"
fi

# Kept as a consistent place to look, and so anything that read it before still
# works — but it now holds the published constant, not a secret.
printf '%s\n' "$SPLUNK_ADMIN_PASSWORD" > ~/splunk-admin-password.txt
chmod 600 ~/splunk-admin-password.txt

step "workshop environment file"
if [ ! -f /home/splunk/.workshop-env ]; then
  # Same file 00-setup step 11 writes by hand. The heredoc is UNQUOTED so the
  # pinned versions come from versions.env — but every $( ) is escaped, so it
  # stays literal in the file and is evaluated on each `source`. That is what
  # keeps LOCAL_IP/PUB_DNS correct after a stop/start gives the instance a new
  # address.
  sudo -u splunk tee /home/splunk/.workshop-env >/dev/null <<EOF
# Workshop session variables. Loaded automatically by ~/.profile (step 13).
# In a shell that hasn't loaded it:  source ~/.workshop-env

# Your username. Prefixes every resource you create so attendees sharing a
# Splunk or Observability Cloud environment don't collide.
export WS_USER=CHANGE_ME

# This instance's private IP — what the Collector uses to reach Splunk's HEC.
export LOCAL_IP=\$(ec2metadata --local-ipv4 2>/dev/null || hostname -I | awk '{print \$1}')

# The public DNS name — what you point a browser at, and what Log Observer
# Connect uses to reach this instance in AW #2.
export PUB_DNS=\$(ec2metadata --public-hostname 2>/dev/null || curl -s ifconfig.me)

# Pinned versions, so commands can be copied without editing.
export CHART_VERSION=${OTEL_CHART_VERSION}
export JAVA_HOME=/usr/lib/jvm/java-${JDK_VERSION}-openjdk-amd64

# Filled in as you go:
#   HEC_TOKEN      — Foundational Workshop #2, step 3
#   O11Y_REALM     — Advanced Workshop #2, step 1
EOF
  sudo chmod 600 /home/splunk/.workshop-env
  sudo chown splunk:splunk /home/splunk/.workshop-env
  ok "/home/splunk/.workshop-env created — now set WS_USER:"
  printf '      sudo sed -i "s/^export WS_USER=.*/export WS_USER=<your-username>/" /home/splunk/.workshop-env\n' 
else
  ok "environment file already present"
fi

step "splunk shell environment"
# Two blocks, guarded independently so re-running this script on a host that
# only has the older docker-env hook still gains the env auto-load.
#
# F14: without the first block every variable is empty in a fresh login shell,
# and nothing errors — `helm upgrade ${WS_USER}-k8s-ws ...` quietly becomes
# `helm upgrade -k8s-ws ...`, a different release name. Sourcing .workshop-env
# was previously only an optional tip in the guide; it is now step 13, and this
# must produce the same .profile the manual path does.
sudo touch /home/splunk/.profile
sudo chown splunk:splunk /home/splunk/.profile
if ! sudo grep -qF 'k8s workshop — load the session variables' /home/splunk/.profile 2>/dev/null; then
  sudo -u splunk tee -a /home/splunk/.profile >/dev/null <<'EOF'

# k8s workshop — load the session variables in every login shell
[ -f ~/.workshop-env ] && . ~/.workshop-env
EOF
fi
ok "~/.workshop-env auto-load added to /home/splunk/.profile"

if ! sudo grep -qF 'k8s workshop — point docker at minikube' /home/splunk/.profile 2>/dev/null; then
  sudo -u splunk tee -a /home/splunk/.profile >/dev/null <<'EOF'

# k8s workshop — point docker at minikube's daemon
if command -v minikube >/dev/null && minikube status >/dev/null 2>&1; then
  eval "$(minikube -p minikube docker-env)"
fi
EOF
fi
ok "docker-env hook added"

printf '\n\033[32mHost ready.\033[0m Next:\n'
printf '  1. set your username (it is CHANGE_ME until you do):\n'
printf '       sudo sed -i "s/^export WS_USER=.*/export WS_USER=<your-username>/" /home/splunk/.workshop-env\n'
printf '  2. sudo -i -u splunk\n'
printf '  3. echo "$WS_USER on $LOCAL_IP ($PUB_DNS)"    # empty output = .profile not loading the file\n'
printf '  4. ~/k8s-otel-workshop/scripts/verify-setup.sh\n'
printf '\n  Splunk admin:     %s / %s\n' "$SPLUNK_ADMIN_USER" "$SPLUNK_ADMIN_PASSWORD"
printf '  Service account:  %s / %s   (you create this in AW2 step 4)\n' "$LOC_SVC_USER" "$LOC_SVC_PASSWORD"
printf '\n  Fixed workshop credentials on a disposable instance. Restrict port 8000 to\n'
printf '  your own IP in the security group, and never reuse these anywhere real.\n'
