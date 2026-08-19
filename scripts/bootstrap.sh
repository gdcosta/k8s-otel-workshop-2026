#!/usr/bin/env bash
# Builds the workshop host from a blank Ubuntu 24.04 x86-64 instance.
# Run as the `ubuntu` (admin) user. Idempotent — safe to re-run.
set -uo pipefail
cd "$(dirname "$0")/.."
source ./versions.env

export DEBIAN_FRONTEND=noninteractive
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
if ! minikube version 2>/dev/null | grep -q "${MINIKUBE_VERSION#v}"; then
  curl -fsSLO "https://github.com/kubernetes/minikube/releases/download/${MINIKUBE_VERSION}/minikube-linux-amd64"
  sudo install -m 0755 minikube-linux-amd64 /usr/local/bin/minikube && rm -f minikube-linux-amd64
fi
ok "$(minikube version | head -1)"

step "helm ${HELM_VERSION}"
# get.helm.sh, NOT the baltocdn apt repo — that host fails TLS validation.
if ! helm version --short 2>/dev/null | grep -q "${HELM_VERSION}"; then
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

  ADMIN_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
  sudo -u splunk tee /opt/splunk/etc/system/local/user-seed.conf >/dev/null <<EOF
[user_info]
USERNAME = admin
PASSWORD = ${ADMIN_PW}
EOF
  echo "$ADMIN_PW" > ~/splunk-admin-password.txt; chmod 600 ~/splunk-admin-password.txt
  ok "installed — admin password saved to ~/splunk-admin-password.txt"
else
  ok "already installed"
fi

step "workshop environment file"
if [ ! -f /home/splunk/.workshop-env ]; then
  sudo -u splunk tee /home/splunk/.workshop-env >/dev/null <<EOF
# Workshop session variables. Load with:  source ~/.workshop-env
export WS_USER=\${WS_USER:-CHANGE_ME}
export LOCAL_IP=\$(ec2metadata --local-ipv4 2>/dev/null || hostname -I | awk '{print \$1}')
export PUB_DNS=\$(ec2metadata --public-hostname 2>/dev/null || curl -s ifconfig.me)
export CHART_VERSION=${OTEL_CHART_VERSION}
export JAVA_HOME=/usr/lib/jvm/java-${JDK_VERSION}-openjdk-amd64
# Added as you go:  HEC_TOKEN (FW2 step 3), O11Y_REALM (AW2 step 1)
EOF
  sudo chmod 600 /home/splunk/.workshop-env
  sudo chown splunk:splunk /home/splunk/.workshop-env
  ok "/home/splunk/.workshop-env created — set WS_USER in it"
else
  ok "environment file already present"
fi

step "splunk shell environment"
if ! sudo grep -q 'k8s workshop' /home/splunk/.profile 2>/dev/null; then
  sudo -u splunk tee -a /home/splunk/.profile >/dev/null <<'EOF'

# k8s workshop — point docker at minikube's daemon
if command -v minikube >/dev/null && minikube status >/dev/null 2>&1; then
  eval "$(minikube -p minikube docker-env)"
fi
EOF
fi
ok "docker-env hook added"

printf '\n\033[32mHost ready.\033[0m Next:\n'
printf '  sudo -i -u splunk\n'
printf '  ~/k8s-otel-workshop/scripts/verify-setup.sh\n'
[ -f ~/splunk-admin-password.txt ] && printf '\n  Splunk admin password: %s\n' "$(cat ~/splunk-admin-password.txt)"
