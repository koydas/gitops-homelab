#!/usr/bin/env bash
# Rebuilds the host-level layer this GitOps repo depends on: microk8s,
# its addons, and ArgoCD. Everything after this script is handled by
# `kubectl apply -f bootstrap/root-app.yaml` + Git commits.
#
# Idempotent: safe to re-run on a box that already has some/all of this
# installed — each step checks current state before acting.
#
# Requires: passwordless sudo (or run as a user who can sudo interactively
# and re-run if prompted), and METALLB_RANGE set to a LAN IP range that is
# OUTSIDE your router's DHCP pool (reserve it there first).
#
# Usage:
#   METALLB_RANGE=192.168.1.240-192.168.1.250 ./bootstrap/install-host.sh

set -euo pipefail

MICROK8S_CHANNEL="${MICROK8S_CHANNEL:-1.35/stable}"
METALLB_RANGE="${METALLB_RANGE:?Set METALLB_RANGE, e.g. METALLB_RANGE=192.168.1.240-192.168.1.250 (must be outside the router DHCP pool)}"

log() { echo -e "\n=== $* ===\n"; }

log "Preflight: checking for a conflicting apt containerd install"
if dpkg -l 2>/dev/null | grep -q containerd; then
  echo "ERROR: an apt-installed containerd package is present." >&2
  echo "This is the known root cause of microk8s GPU addon pods hanging in Init" >&2
  echo "(canonical/microk8s#5229). Remove it first: sudo apt purge containerd.io" >&2
  exit 1
fi
echo "OK: no conflicting containerd package."

log "Installing microk8s ($MICROK8S_CHANNEL)"
if snap list microk8s >/dev/null 2>&1; then
  echo "microk8s already installed, skipping."
else
  sudo snap install microk8s --classic --channel="$MICROK8S_CHANNEL"
fi

sudo usermod -a -G microk8s "$USER"
sudo mkdir -p "$HOME/.kube"
sudo chown -f -R "$USER" "$HOME/.kube"

log "Waiting for microk8s to be ready"
sudo microk8s status --wait-ready

log "Enabling core addons: dns, hostpath-storage, helm3"
sudo microk8s enable dns hostpath-storage helm3

log "Enabling metallb ($METALLB_RANGE)"
if sudo microk8s kubectl get ipaddresspool -n metallb-system >/dev/null 2>&1; then
  echo "metallb already enabled, skipping (address pool is Git-managed under apps/metallb-config/ once bootstrapped)."
else
  sudo microk8s enable metallb:"$METALLB_RANGE"
fi

log "Enabling GPU support (nvidia addon, host driver)"
sudo microk8s enable gpu --driver host

log "Waiting for GPU operator pods to be Running/Completed"
until [ "$(sudo microk8s kubectl get pods -n gpu-operator-resources --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)" -eq 0 ] \
   && [ "$(sudo microk8s kubectl get pods -n gpu-operator-resources --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
  sleep 5
done
sudo microk8s kubectl get pods -n gpu-operator-resources

log "Installing ArgoCD"
sudo microk8s kubectl create namespace argocd --dry-run=client -o yaml | sudo microk8s kubectl apply -f -
# --server-side avoids "metadata.annotations: Too long" on the
# applicationsets.argoproj.io CRD, which client-side apply hits because the
# last-applied-configuration annotation exceeds the 262144-byte limit.
sudo microk8s kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side --force-conflicts
sudo microk8s kubectl -n argocd wait --for=condition=available --timeout=300s deployment --all

log "Exposing ArgoCD via MetalLB"
sudo microk8s kubectl -n argocd patch svc argocd-server -p '{"spec": {"type": "LoadBalancer"}}'
until [ -n "$(sudo microk8s kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)" ]; do
  sleep 2
done
ARGOCD_IP="$(sudo microk8s kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
ARGOCD_PW="$(sudo microk8s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || true)"

log "Done"
echo "ArgoCD UI: https://$ARGOCD_IP  (self-signed cert, browser warning expected)"
echo "Login: admin"
if [ -n "$ARGOCD_PW" ]; then
  echo "Initial password: $ARGOCD_PW  (change it on first login)"
else
  echo "Initial password secret not found — ArgoCD was likely already installed and the secret has been rotated/removed."
fi
echo
echo "Next step: sudo microk8s kubectl apply -f bootstrap/root-app.yaml"
echo "This creates the app-of-apps; ArgoCD then syncs everything under apps/ automatically."
