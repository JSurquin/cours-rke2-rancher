#!/usr/bin/env bash
# Installation de TP : RKE2 + Rancher + une application en 2 pods.
# Cible : openSUSE Leap 16, installé directement sur le PC (pas de VM).
#
# Un PC = un nœud Kubernetes. replicas: 2 = deux pods sur ce même nœud.
# Rancher est installé en 1 replica : son chart en demande 3 pour une
# production à trois serveurs, ce qui ne démarre pas correctement ici.
#
# Lancement :
#   sudo bash install-rke2-rancher.sh
#
# Désinstallation (restaure firewalld, le swap et SELinux si ce script
# les avait modifiés) :
#   sudo bash install-rke2-rancher.sh --desinstaller
#
# Réglages modifiables avant de distribuer le script, ou en variables
# d'environnement au moment du lancement :
#   RANCHER_BOOTSTRAP_PASSWORD  mot de passe du premier admin (12 caractères min.)
#   CERT_MANAGER_VERSION        ex. v1.21.3
#   RKE2_CHANNEL                stable par défaut
#   RKE2_VERSION                vide = la version du canal ; ex. v1.33.5+rke2r1
#   RANCHER_VERSION             vide = le dernier chart stable
#   DEMO_REPLICAS               2 par défaut
#   DEMO_IMAGE                  nginx:1.28-alpine par défaut
#   FORCE_LOW_RAM               1 pour continuer sous 4 Go de RAM

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "Lance ce script avec bash : sudo bash $0" >&2
  exit 1
fi

# Un téléchargement via Windows laisse parfois des fins de ligne CRLF.
if grep -q $'\r' "$0" 2>/dev/null; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi

set -euo pipefail
export PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD:-Cours-Rancher-2026}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.3}"
RKE2_CHANNEL="${RKE2_CHANNEL:-stable}"
RKE2_VERSION="${RKE2_VERSION:-}"
RANCHER_VERSION="${RANCHER_VERSION:-}"
RANCHER_CHART_URL="${RANCHER_CHART_URL:-https://releases.rancher.com/server-charts/stable}"
DEMO_REPLICAS="${DEMO_REPLICAS:-2}"
DEMO_IMAGE="${DEMO_IMAGE:-nginx:1.28-alpine}"
DEMO_NODEPORT="${DEMO_NODEPORT:-30080}"
FORCE_LOW_RAM="${FORCE_LOW_RAM:-0}"

LAB_DIR="/var/lib/lab-rke2-rancher"
KUBECONFIG_PATH="/etc/rancher/rke2/rke2.yaml"
RKE2_BIN_DIR="/var/lib/rancher/rke2/bin"
STATE_DIR="${LAB_DIR}/etat"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '\n!!  %s\n' "$*" >&2; }
die()  { printf '\nERREUR : %s\n' "$*" >&2; exit 1; }

on_err() {
  local line="$1"
  warn "Le script s'est arrêté à la ligne ${line}."
  warn "Tu peux le relancer : les étapes déjà faites sont reprises."
  warn "Journaux RKE2 : journalctl -u rke2-server -n 80 --no-pager"
}
trap 'on_err $LINENO' ERR

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Lance le script en root : sudo bash $0 $*"
  fi
}

# ---------------------------------------------------------------------------
# Désinstallation
# ---------------------------------------------------------------------------

desinstaller() {
  need_root --desinstaller
  log "Désinstallation du TP RKE2 / Rancher"

  if [[ -x "${RKE2_BIN_DIR}/kubectl" && -f "${KUBECONFIG_PATH}" ]]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
    export PATH="${RKE2_BIN_DIR}:${PATH}"
    helm uninstall rancher -n cattle-system --wait --timeout 5m || true
    helm uninstall cert-manager -n cert-manager --wait --timeout 5m || true
    kubectl delete namespace demo --wait=false || true
  fi

  if [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
    /usr/local/bin/rke2-uninstall.sh
  elif [[ -x /opt/rke2/bin/rke2-uninstall.sh ]]; then
    /opt/rke2/bin/rke2-uninstall.sh
  elif [[ -x /usr/bin/rke2-uninstall.sh ]]; then
    /usr/bin/rke2-uninstall.sh
  else
    warn "rke2-uninstall.sh introuvable : RKE2 n'était peut-être pas installé."
  fi

  rm -f /etc/profile.d/rke2-lab.sh
  rm -f /etc/NetworkManager/conf.d/rke2-canal.conf
  rm -f /etc/sysctl.d/99-rke2-lab.conf
  rm -f /etc/modules-load.d/rke2-lab.conf
  rm -f /etc/zypp/repos.d/rancher-rke2-common-stable.repo

  if [[ -L /usr/local/bin/kubectl ]]; then rm -f /usr/local/bin/kubectl; fi
  if [[ -L /usr/local/bin/crictl ]]; then rm -f /usr/local/bin/crictl; fi

  if [[ -f /etc/hosts ]]; then
    sed -i '/# lab-rke2-rancher/d' /etc/hosts
  fi

  if [[ -f "${STATE_DIR}/fstab.avant" ]]; then
    cp -a "${STATE_DIR}/fstab.avant" /etc/fstab
    swapon -a || true
    log "Swap restauré depuis la copie de /etc/fstab."
  fi

  if [[ -f "${STATE_DIR}/selinux.avant" ]]; then
    local mode
    mode="$(cat "${STATE_DIR}/selinux.avant")"
    if [[ -f /etc/selinux/config ]]; then
      sed -i "s/^SELINUX=.*/SELINUX=$(printf '%s' "${mode}" | tr '[:upper:]' '[:lower:]')/" /etc/selinux/config
    fi
    case "${mode}" in
      Enforcing) setenforce 1 || true ;;
      Permissive) setenforce 0 || true ;;
    esac
    log "SELinux remis en mode ${mode} (un redémarrage finit de l'appliquer)."
  fi

  if [[ -f "${STATE_DIR}/firewalld.etait-actif" ]]; then
    systemctl enable --now firewalld || true
    log "firewalld a été réactivé."
  fi

  if systemctl is-active --quiet NetworkManager; then
    systemctl reload NetworkManager || true
  fi

  rm -rf "${LAB_DIR}"
  log "Désinstallation terminée. Ouvre un nouveau terminal pour perdre l'ancien PATH."
}

if [[ "${1:-}" == "--desinstaller" || "${1:-}" == "--uninstall" ]]; then
  desinstaller
  exit 0
fi

if [[ $# -gt 0 ]]; then
  die "Argument inconnu : $1. Utilise --desinstaller pour tout retirer."
fi

# ---------------------------------------------------------------------------
# Contrôles
# ---------------------------------------------------------------------------

need_root

if [[ ${#RANCHER_BOOTSTRAP_PASSWORD} -lt 12 ]]; then
  die "RANCHER_BOOTSTRAP_PASSWORD doit faire au moins 12 caractères."
fi
if [[ "${RANCHER_BOOTSTRAP_PASSWORD}" == *"'"* ]]; then
  die "Le mot de passe ne doit pas contenir d'apostrophe simple."
fi
if ! [[ "${DEMO_REPLICAS}" =~ ^[0-9]+$ ]] || [[ "${DEMO_REPLICAS}" -lt 1 ]]; then
  die "DEMO_REPLICAS doit être un entier supérieur à 0."
fi

log "Contrôle du système"
if [[ ! -r /etc/os-release ]]; then
  die "Fichier /etc/os-release introuvable."
fi
# shellcheck disable=SC1091
. /etc/os-release
os_major="${VERSION_ID%%.*}"
if [[ "${ID:-}" != "opensuse-leap" || "${os_major}" != "16" ]]; then
  die "Ce script est prévu pour openSUSE Leap 16 (détecté : ${PRETTY_NAME:-inconnu})."
fi
case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) die "Architecture non prise en charge : $(uname -m). Il faut x86_64 ou arm64." ;;
esac

mem_kib="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
mem_gib="$((mem_kib / 1024 / 1024))"
if (( mem_kib < 4 * 1024 * 1024 )); then
  if [[ "${FORCE_LOW_RAM}" != "1" ]]; then
    die "RAM détectée : environ ${mem_gib} Go. Il en faut au moins 4, et 8 pour que le bureau reste utilisable. Relance avec FORCE_LOW_RAM=1 pour ignorer ce contrôle."
  fi
  warn "RAM très faible (${mem_gib} Go). Le cluster peut être instable."
elif (( mem_kib < 8 * 1024 * 1024 )); then
  warn "RAM détectée : environ ${mem_gib} Go. 8 Go ou plus évitent les blocages pendant l'installation. Ferme le navigateur et les applications lourdes."
else
  log "RAM : environ ${mem_gib} Go."
fi

avail_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
avail_gib="$((avail_kib / 1024 / 1024))"
if (( avail_kib < 15 * 1024 * 1024 )); then
  die "Espace libre sur / : environ ${avail_gib} Go. Il en faut au moins 15."
fi

if ! curl -fsS --max-time 20 -o /dev/null https://get.rke2.io; then
  die "Impossible de joindre https://get.rke2.io. Vérifie la connexion Internet (et le proxy de l'établissement, variables https_proxy / http_proxy)."
fi

mkdir -p "${LAB_DIR}" "${STATE_DIR}" /etc/rancher/rke2
chmod 755 "${LAB_DIR}"
chmod 700 "${STATE_DIR}"

# ---------------------------------------------------------------------------
# Paquets et préparation de l'hôte
# ---------------------------------------------------------------------------

log "Installation des paquets nécessaires"
zypper -n refresh || warn "zypper refresh a signalé un problème. L'installation des paquets continue."
zypper -n install --no-recommends curl ca-certificates tar gzip gawk iptables

if [[ -f /sys/module/apparmor/parameters/enabled ]] && grep -q Y /sys/module/apparmor/parameters/enabled; then
  log "AppArmor est actif (souvent le cas après une migration depuis Leap 15). Installation d'apparmor-parser."
  zypper -n install --no-recommends apparmor-parser
fi

log "Paramètres noyau utilisés par le réseau Kubernetes"
cat > /etc/modules-load.d/rke2-lab.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay || warn "Module overlay non chargé."
modprobe br_netfilter || warn "Module br_netfilter non chargé."

cat > /etc/sysctl.d/99-rke2-lab.conf <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
  sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null
fi

log "Arrêt du swap (Kubernetes refuse de démarrer tant qu'il est actif)"
if [[ ! -f "${STATE_DIR}/fstab.avant" ]]; then
  cp -a /etc/fstab "${STATE_DIR}/fstab.avant"
fi
swapoff -a || true
awk '
  /^[[:space:]]*#/ { print; next }
  $3 == "swap" { print "# lab-rke2-rancher " $0; next }
  { print }
' /etc/fstab > /etc/fstab.rke2-lab
cat /etc/fstab.rke2-lab > /etc/fstab
rm -f /etc/fstab.rke2-lab
if [[ -n "$(swapon --show 2>/dev/null || true)" ]]; then
  warn "Du swap est encore actif. S'il revient après un redémarrage, kubelet peut refuser de démarrer."
fi

if systemctl is-active --quiet firewalld || systemctl is-enabled --quiet firewalld; then
  log "Arrêt de firewalld : il entre en conflit avec Canal, le réseau par défaut de RKE2"
  if [[ ! -f "${STATE_DIR}/firewalld.etait-actif" ]]; then
    touch "${STATE_DIR}/firewalld.etait-actif"
  fi
  systemctl disable --now firewalld
fi

log "NetworkManager ignore les interfaces du réseau des pods"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/rke2-canal.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:flannel*;interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali;interface-name:cni0
EOF
if systemctl is-active --quiet NetworkManager; then
  systemctl reload NetworkManager || warn "Recharge de NetworkManager impossible. Un redémarrage du PC réglera ça si les pods n'ont pas de réseau."
fi
systemctl disable --now nm-cloud-setup.service nm-cloud-setup.timer >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Adresse du nœud
# ---------------------------------------------------------------------------

node_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
if [[ -z "${node_ip}" ]]; then
  node_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
fi
if [[ -z "${node_ip}" || "${node_ip}" == 127.* ]]; then
  die "Impossible de trouver une adresse IPv4 de ce PC. Connecte-le au réseau, puis relance."
fi

RANCHER_HOST="${node_ip}.sslip.io"
DEMO_HOST="bonjour.${node_ip}.sslip.io"
log "Adresse de ce PC : ${node_ip}"
log "Rancher sera exposé sur https://${RANCHER_HOST}"
log "L'application de démo sera aussi sur http://${DEMO_HOST} et http://127.0.0.1:${DEMO_NODEPORT}"

# ---------------------------------------------------------------------------
# SELinux
# Leap 16 est en enforcing. L'installeur RKE2 officiel passe par une archive
# (pas par les RPM) sur openSUSE, donc la politique rke2-selinux n'est pas
# installée toute seule. On l'installe avant RKE2, pour que les fichiers
# reçoivent le bon contexte.
# ---------------------------------------------------------------------------

selinux_mode() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce
    return
  fi
  if [[ -f /sys/fs/selinux/enforce ]]; then
    if [[ "$(cat /sys/fs/selinux/enforce)" == "1" ]]; then
      echo Enforcing
    else
      echo Permissive
    fi
    return
  fi
  echo Disabled
}

use_selinux_config="false"
mode="$(selinux_mode)"
log "SELinux : ${mode}"

if [[ "${mode}" != "Disabled" ]]; then
  if ! rpm -q rke2-selinux >/dev/null 2>&1; then
    log "Installation de la politique SELinux rke2-selinux"
    cat > /etc/zypp/repos.d/rancher-rke2-common-stable.repo <<'EOF'
[rancher-rke2-common-stable]
name=Rancher RKE2 Common (stable)
baseurl=https://rpm.rancher.io/rke2/stable/common/slemicro/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://rpm.rancher.io/public.key
EOF
    selinux_ok="non"
    if zypper --gpg-auto-import-keys refresh rancher-rke2-common-stable && \
       zypper -n install --no-recommends rke2-selinux; then
      selinux_ok="oui"
    else
      warn "Le dépôt Rancher n'a pas fourni rke2-selinux. Essai avec le dépôt openSUSE devel:microos pour Leap 16."
      zypper -n addrepo -f https://download.opensuse.org/repositories/devel:microos/16.0/devel:microos.repo || true
      if zypper --gpg-auto-import-keys refresh && zypper -n install --no-recommends rke2-selinux; then
        selinux_ok="oui"
      fi
    fi

    if [[ "${selinux_ok}" != "oui" ]]; then
      warn "Politique rke2-selinux indisponible. SELinux passe en permissif pour que le TP puisse démarrer."
      if [[ ! -f "${STATE_DIR}/selinux.avant" ]]; then
        printf '%s\n' "${mode}" > "${STATE_DIR}/selinux.avant"
      fi
      setenforce 0 || true
      if [[ -f /etc/selinux/config ]]; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
      fi
      mode="Permissive"
    fi
  fi

  if rpm -q rke2-selinux >/dev/null 2>&1; then
    use_selinux_config="true"
  fi
fi

# ---------------------------------------------------------------------------
# RKE2
# ---------------------------------------------------------------------------

if ! systemctl is-active --quiet rke2-server; then
  log "Écriture de /etc/rancher/rke2/config.yaml"
  {
    echo "write-kubeconfig-mode: \"0644\""
    echo "cni: canal"
    echo "tls-san:"
    echo "  - ${node_ip}"
    echo "  - ${RANCHER_HOST}"
    echo "  - ${DEMO_HOST}"
    if [[ "${use_selinux_config}" == "true" ]]; then
      echo "selinux: true"
    fi
  } > /etc/rancher/rke2/config.yaml

  if [[ ! -x /usr/local/bin/rke2 && ! -x /usr/bin/rke2 && ! -x /opt/rke2/bin/rke2 ]]; then
    log "Téléchargement et installation de RKE2 (canal ${RKE2_CHANNEL}). Cela peut prendre plusieurs minutes."
    install_env=(INSTALL_RKE2_CHANNEL="${RKE2_CHANNEL}")
    if [[ -n "${RKE2_VERSION}" ]]; then
      install_env+=(INSTALL_RKE2_VERSION="${RKE2_VERSION}")
    fi
    curl -sfL https://get.rke2.io | env "${install_env[@]}" sh -
  else
    log "Les binaires RKE2 sont déjà présents."
  fi

  systemctl enable rke2-server.service
  log "Démarrage de RKE2. Le premier lancement télécharge les images système."
  systemctl start rke2-server.service
else
  log "RKE2 tourne déjà : la configuration existante est conservée."
fi

log "Attente de kubectl"
kubectl_ok="non"
for _ in $(seq 1 60); do
  if [[ -x "${RKE2_BIN_DIR}/kubectl" && -f "${KUBECONFIG_PATH}" ]]; then
    kubectl_ok="oui"
    break
  fi
  sleep 5
done
if [[ "${kubectl_ok}" != "oui" ]]; then
  journalctl -u rke2-server -n 40 --no-pager || true
  die "kubectl n'est pas apparu. Si des refus SELinux sont dans le journal, redémarre le PC puis relance ce script."
fi

export KUBECONFIG="${KUBECONFIG_PATH}"
export PATH="${RKE2_BIN_DIR}:${PATH}"
ln -sfn "${RKE2_BIN_DIR}/kubectl" /usr/local/bin/kubectl
ln -sfn "${RKE2_BIN_DIR}/crictl" /usr/local/bin/crictl

cat > /etc/profile.d/rke2-lab.sh <<EOF
export PATH="${RKE2_BIN_DIR}:\$PATH"
export KUBECONFIG="${KUBECONFIG_PATH}"
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
EOF
chmod 644 /etc/profile.d/rke2-lab.sh

log "Attente du nœud Ready (jusqu'à 15 minutes)"
node_ready="non"
for _ in $(seq 1 90); do
  if kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -qx Ready; then
    node_ready="oui"
    break
  fi
  sleep 10
done
if [[ "${node_ready}" != "oui" ]]; then
  kubectl get nodes -o wide || true
  kubectl get pods -A || true
  journalctl -u rke2-server -n 40 --no-pager || true
  die "Le nœud n'est pas passé Ready. Redémarre le PC si SELinux vient d'être configuré, puis relance ce script."
fi
kubectl get nodes -o wide

log "Attente de CoreDNS et de l'ingress"
kubectl -n kube-system rollout status deploy/rke2-coredns --timeout=300s
if kubectl -n kube-system get ds rke2-ingress-nginx-controller >/dev/null 2>&1; then
  kubectl -n kube-system rollout status ds/rke2-ingress-nginx-controller --timeout=300s
fi

ingress_class=""
for _ in $(seq 1 30); do
  if kubectl get ingressclass nginx >/dev/null 2>&1; then
    ingress_class="nginx"
    break
  fi
  ingress_class="$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${ingress_class}" ]]; then
    break
  fi
  sleep 5
done
if [[ -z "${ingress_class}" ]]; then
  die "Aucune IngressClass trouvée. L'ingress RKE2 n'a pas démarré."
fi
log "IngressClass utilisée : ${ingress_class}"

# ---------------------------------------------------------------------------
# Helm, cert-manager, Rancher
# ---------------------------------------------------------------------------

install_helm() {
  if command -v helm >/dev/null 2>&1; then
    local version major minor
    version="$(helm version --template '{{.Version}}' 2>/dev/null || echo v0.0.0)"
    if [[ "${version}" =~ ^v([0-9]+)\.([0-9]+) ]]; then
      major="${BASH_REMATCH[1]}"
      minor="${BASH_REMATCH[2]}"
    else
      major=0
      minor=0
    fi
    if [[ "${major}" -gt 3 || ( "${major}" -eq 3 && "${minor}" -ge 18 ) ]]; then
      log "Helm ${version} est déjà assez récent."
      return
    fi
    warn "Helm ${version} est trop ancien pour Rancher récent. Installation de la dernière version 3."
  fi
  log "Installation de Helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  hash -r
}

install_helm
command -v helm >/dev/null 2>&1 || die "Helm n'est pas disponible dans le PATH."

if ! kubectl -n cert-manager rollout status deploy/cert-manager --timeout=15s >/dev/null 2>&1; then
  log "Installation de cert-manager ${CERT_MANAGER_VERSION}"
  helm upgrade --install cert-manager "oci://quay.io/jetstack/charts/cert-manager" \
    --version "${CERT_MANAGER_VERSION}" \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait \
    --timeout 10m
fi
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s

webhook_ok="non"
for _ in $(seq 1 30); do
  if kubectl -n cert-manager get endpoints cert-manager-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    webhook_ok="oui"
    break
  fi
  sleep 5
done
if [[ "${webhook_ok}" != "oui" ]]; then
  die "Le webhook cert-manager n'a pas d'adresse. Regarde : kubectl -n cert-manager get pods"
fi

helm repo add --force-update rancher-stable "${RANCHER_CHART_URL}"
helm repo update rancher-stable

cat > "${LAB_DIR}/rancher-values.yaml" <<EOF
hostname: ${RANCHER_HOST}
replicas: 1
bootstrapPassword: '${RANCHER_BOOTSTRAP_PASSWORD}'
antiAffinity: preferred
ingress:
  tls:
    source: rancher
  ingressClassName: ${ingress_class}
EOF
chmod 600 "${LAB_DIR}/rancher-values.yaml"

current_rancher_host="$(kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
if [[ "${current_rancher_host}" == "${RANCHER_HOST}" ]] && \
   kubectl -n cattle-system rollout status deploy/rancher --timeout=15s >/dev/null 2>&1; then
  log "Rancher est déjà prêt sur https://${RANCHER_HOST}"
else
  log "Installation de Rancher (1 replica sur ce nœud). Encore plusieurs minutes."
  helm_args=(
    upgrade --install rancher rancher-stable/rancher
    --namespace cattle-system
    --create-namespace
    --values "${LAB_DIR}/rancher-values.yaml"
    --wait
    --timeout 20m
  )
  if [[ -n "${RANCHER_VERSION}" ]]; then
    helm_args+=(--version "${RANCHER_VERSION}")
  fi
  if ! helm "${helm_args[@]}"; then
    kubectl get pods -A || true
    die "L'installation Helm de Rancher a échoué."
  fi
fi
kubectl -n cattle-system rollout status deploy/rancher --timeout=300s

# ---------------------------------------------------------------------------
# Application de démonstration : 2 pods, 1 nœud
# ---------------------------------------------------------------------------

log "Déploiement de l'application (replicas: ${DEMO_REPLICAS})"
cat > "${LAB_DIR}/demo-app.yaml" <<EOF
# Application de TP.
# replicas = nombre de pods, pas nombre de machines.
# Ce PC est le seul nœud : les ${DEMO_REPLICAS} pods sont placés dessus.
apiVersion: v1
kind: Namespace
metadata:
  name: demo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bonjour
  namespace: demo
spec:
  replicas: ${DEMO_REPLICAS}
  selector:
    matchLabels:
      app: bonjour
  template:
    metadata:
      labels:
        app: bonjour
    spec:
      containers:
        - name: web
          image: ${DEMO_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          command: ["/bin/sh", "-c"]
          args:
            - |
              cat > /usr/share/nginx/html/index.html <<HTML
              <!DOCTYPE html>
              <html lang="fr">
              <head><meta charset="utf-8"><title>Démo RKE2</title></head>
              <body>
              <h1>Application de démonstration</h1>
              <p>Pod : <strong>\$POD_NAME</strong></p>
              <p>Nœud : <strong>\$NODE_NAME</strong></p>
              <p>Le déploiement demande ${DEMO_REPLICAS} réplicas. Ce PC est un seul nœud Kubernetes, donc ces pods tournent tous sur cette machine.</p>
              <p>Recharge la page plusieurs fois : le service répartit les requêtes entre les pods.</p>
              </body>
              </html>
              HTML
              exec nginx -g 'daemon off;'
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 20m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: bonjour
  namespace: demo
spec:
  selector:
    app: bonjour
  ports:
    - name: http
      port: 80
      targetPort: http
      nodePort: ${DEMO_NODEPORT}
  type: NodePort
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bonjour
  namespace: demo
spec:
  ingressClassName: ${ingress_class}
  rules:
    - host: ${DEMO_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: bonjour
                port:
                  number: 80
EOF

kubectl apply -f "${LAB_DIR}/demo-app.yaml"
kubectl -n demo rollout status deploy/bonjour --timeout=300s
kubectl -n demo get pods -o wide

log "Vérification HTTP sur le NodePort"
sleep 2
if curl -fsS --max-time 15 "http://127.0.0.1:${DEMO_NODEPORT}/" >/dev/null; then
  log "L'application répond sur http://127.0.0.1:${DEMO_NODEPORT}/"
else
  warn "Le NodePort ne répond pas encore. Regarde : kubectl -n demo describe pods"
fi

cat > "${LAB_DIR}/acces.txt" <<EOF
Rancher : https://${RANCHER_HOST}
Utilisateur : admin
Mot de passe initial : ${RANCHER_BOOTSTRAP_PASSWORD}

Au premier accès, le navigateur signale un certificat auto-signé : c'est attendu
sur ce TP. Accepte l'exception de sécurité.

Rancher demande ensuite de choisir un nouveau mot de passe d'au moins
12 caractères, différent de celui-ci.

Application (2 pods sur ce seul nœud) :
  http://127.0.0.1:${DEMO_NODEPORT}/
  http://${DEMO_HOST}/

Commandes :
  kubectl get nodes -o wide
  kubectl -n demo get pods -o wide
  kubectl -n demo get svc,ingress

Manifeste de l'application :
  ${LAB_DIR}/demo-app.yaml

Désinstallation :
  sudo bash install-rke2-rancher.sh --desinstaller
EOF
chmod 644 "${LAB_DIR}/acces.txt"

cat <<EOF

Installation terminée.

  Nœud Kubernetes : ce PC (${node_ip}), un seul.
  Pods de l'application : ${DEMO_REPLICAS}, tous sur ce nœud.
  Rancher : 1 replica (le chart en prévoit 3 seulement quand il y a plusieurs serveurs).

  Interface Rancher : https://${RANCHER_HOST}
  Utilisateur       : admin
  Mot de passe      : ${RANCHER_BOOTSTRAP_PASSWORD}

  Le certificat est auto-signé : le navigateur affiche un avertissement.
  Au premier login, choisis un nouveau mot de passe d'au moins 12 caractères.

  Application : http://127.0.0.1:${DEMO_NODEPORT}/
                http://${DEMO_HOST}/

  Ouvre un nouveau terminal, puis :
    kubectl get nodes -o wide
    kubectl -n demo get pods -o wide

  Les deux pods doivent afficher le même nom dans la colonne NODE.
  Le rappel des accès est dans ${LAB_DIR}/acces.txt

  firewalld a été arrêté s'il était actif, et le swap a été désactivé.
  Pour remettre la machine comme avant :
    sudo bash install-rke2-rancher.sh --desinstaller

EOF
