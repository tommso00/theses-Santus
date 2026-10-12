#!/usr/bin/env bash
# =============================================================================
# Misconfig 2 - Workloads scheduled on control-plane nodes (STRIDE riga 8)
#
# Mostra che: su Minikube l'unico nodo e' anche il control plane, non ha taint,
# e i pod dello stack girano accanto a etcd/kube-apiserver. Misura poi il
# carico del nodo per far vedere che i workload competono col control plane.
#
# Uso:   ./02-control-plane-scheduling.sh [namespace]
#        METRICS=1 ./02-control-plane-scheduling.sh   # abilita metrics-server e misura
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
line() { printf '\n=== %s\n' "$1"; }
command -v kubectl >/dev/null || { echo "serve kubectl nel PATH"; exit 1; }

line "1. Quanti nodi, con quale ruolo?"
kubectl get nodes -o custom-columns='NODE:.metadata.name,ROLES:.metadata.labels.kubernetes\.io/hostname,CP:.metadata.labels.node-role\.kubernetes\.io/control-plane'
kubectl get nodes -o wide

line "2. Il nodo control-plane ha un taint che impedisce lo scheduling?"
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'
echo "(atteso su Minikube: nessun taint -> i pod applicativi possono finire qui)"

line "3. I pod dello stack e i componenti del control plane sono sullo stesso nodo?"
echo "-- Stack $NS:"
kubectl get pods -n "$NS" -o wide --no-headers | awk '{print $1"\t"$7}'
echo "-- Control plane (kube-system):"
kubectl get pods -n kube-system -o wide --no-headers \
  | grep -E 'etcd|apiserver|controller-manager|scheduler' | awk '{print $1"\t"$7}'

if [ "${METRICS:-0}" = "1" ]; then
  line "4. Carico del nodo (serve metrics-server)"
  minikube addons enable metrics-server >/dev/null 2>&1 || \
    echo "(metrics-server non abilitabile da qui: abilitarlo manualmente)"
  sleep 20
  kubectl top node || true
  kubectl top pods -n "$NS" --sort-by=cpu || true
  line "5. Latenza dell'API server sotto carico"
  for i in 1 2 3; do
    /usr/bin/time -f "  chiamata $i: %e s" kubectl get pods -A >/dev/null
  done
  echo "Ripetere aumentando edges[].pmu nei values e reinstallando: se la latenza"
  echo "cresce, i workload stanno degradando il control plane."
fi

echo
echo "CONCLUSIONE: un solo nodo non isolato ospita sia il control plane sia i pod"
echo "(openPDC compreso). Niente separazione: un'evasione dal container o un picco"
echo "di risorse colpisce direttamente etcd e l'API server."
