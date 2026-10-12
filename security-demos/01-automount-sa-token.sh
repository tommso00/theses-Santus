#!/usr/bin/env bash
# =============================================================================
# Misconfig 1 - Automounted high-privilege ServiceAccount tokens
#
# Mostra che: ogni pod dello stack monta il token del ServiceAccount "default",
# che l'API server e' raggiungibile dai pod (egress non filtrato) e che il
# token viene ACCETTATO.
#
# Uso:   ./01-automount-sa-token.sh [namespace]
#        LAB=1 ./01-automount-sa-token.sh   # esegue anche l'esperimento di escalation
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
SA="system:serviceaccount:${NS}:default"

line() { printf '\n=== %s\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
need kubectl

line "1. Quale ServiceAccount usano i pod e il token e' montato?"
kubectl get pods -n "$NS" \
  -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName,AUTOMOUNT:.spec.automountServiceAccountToken'
echo "(SA vuoto = 'default'; AUTOMOUNT vuoto = default true, cioe' il token e' montato)"

POD="$(kubectl get pods -n "$NS" -l smartgrid.io/role=openpdc -o name | head -n1)"
[ -n "$POD" ] || POD="$(kubectl get pods -n "$NS" -o name | head -n1)"
line "2. Il token e' davvero nel filesystem del pod ($POD)?"
kubectl exec -n "$NS" "$POD" -- ls -l /var/run/secrets/kubernetes.io/serviceaccount/ || true

line "3. Che permessi ha il ServiceAccount default?"
kubectl auth can-i --list -n "$NS" --as="$SA" || true

line "4. L'API server e' raggiungibile dal pod e accetta il token?"
# 403 = autenticazione riuscita (token valido) ma autorizzazione negata: e' il risultato atteso.
kubectl exec -n "$NS" "$POD" -- sh -c '
  T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  code=$(wget -q -O /dev/null -S --no-check-certificate \
      --header="Authorization: Bearer $T" \
      "https://kubernetes.default.svc/api/v1/namespaces/'"$NS"'/secrets" 2>&1 \
      | awk "/HTTP\//{print \$2; exit}")
  echo "HTTP code dall API server: ${code:-nessuna risposta}"
' || echo "(se wget non c'e' nell'immagine, rifare il test con un pod curlimages/curl)"

if [ "${LAB:-0}" = "1" ]; then
  line "5. LAB - lego un ruolo read-secrets al default e ripeto il test"
  cleanup() {
    kubectl delete rolebinding default-read-secrets -n "$NS" --ignore-not-found
    kubectl delete role read-secrets -n "$NS" --ignore-not-found
  }
  trap cleanup EXIT
  kubectl create role read-secrets -n "$NS" --verb=get,list --resource=secrets
  kubectl create rolebinding default-read-secrets -n "$NS" \
    --role=read-secrets --serviceaccount="${NS}:default"
  echo "Ora il default puo' leggere i Secret:"
  kubectl auth can-i get secrets -n "$NS" --as="$SA"   # atteso: yes
  echo "...e lo puo' fare da QUALSIASI pod, openPDC compreso. Rimuovo il binding (trap EXIT)."
fi

echo
echo "CONCLUSIONE: tutti i pod condividono un'unica identita' con token montato e"
echo "l'API server e' raggiungibile. Un singolo RoleBinding sul default propaga i"
echo "permessi a ogni componente, incluso quello piu' esposto (openPDC)."
