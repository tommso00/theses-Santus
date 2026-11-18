#!/usr/bin/env bash
# =============================================================================
# Misconfig 2 - Workloads scheduled on control-plane nodes (STRIDE riga 8)
#
# Verifica che NESSUNA policy, a nessun livello, tenga i pod applicativi
# lontani dal nodo del control plane:
#   1. workload (chart): nodeSelector, affinity, tolerations, priorityClassName
#   2. nodo: taint NoSchedule sul control plane
#   3. admission: ValidatingAdmissionPolicy, webhook sui pod, Kyverno/Gatekeeper
#   4. namespace: ResourceQuota, LimitRange, priorita' dei pod
#   5. esito: su quale nodo sono finiti i pod dello stack
# Con LAB=1:
#   6. un pod che chiede ESPLICITAMENTE il control plane viene accettato
#      dall'admission (dry-run lato server) e collocato (pod "pause" temporaneo)
# Con LAB=1 POLICY=1:
#   7. applica per pochi secondi le due policy mancanti (taint NoSchedule e una
#      ValidatingAdmissionPolicy) e ripete le stesse richieste: il pod senza
#      vincoli resta Pending, quello che chiede il control plane e' rifiutato.
#
# Uso:   ./02-control-plane-scheduling.sh [namespace]
#        LAB=1 ./02-control-plane-scheduling.sh
#        LAB=1 POLICY=1 ./02-control-plane-scheduling.sh
#
# Tutto cio' che i passi LAB creano (pod, taint, policy) viene rimosso a fine
# run da un trap EXIT, anche in caso di errore. I pod dello stack non vengono
# toccati: il taint NoSchedule non sposta i pod gia' in esecuzione.
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
CP_KEY="node-role.kubernetes.io/control-plane"
LAB_NAME="misconfig2-lab"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"
LAB="${LAB:-0}"
POLICY="${POLICY:-0}"

line() { printf '\n=== %s\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
need kubectl
kubectl get ns "$NS" >/dev/null || { echo "namespace '$NS' non trovato"; exit 1; }

CP_NODES="$(kubectl get nodes -l "$CP_KEY" -o jsonpath='{.items[*].metadata.name}')"
[ -n "$CP_NODES" ] || { echo "nessun nodo con l'etichetta $CP_KEY"; exit 1; }
CP_COUNT="$(echo "$CP_NODES" | wc -w | tr -d ' ')"
taints_of() { kubectl get node "$1" -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{" "}{end}'; }

# -----------------------------------------------------------------------------
line "1. Workload: il chart esprime vincoli di collocazione o di priorita'?"
kubectl get deploy,statefulset,daemonset -n "$NS" \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,NODESELECTOR:.spec.template.spec.nodeSelector,AFFINITY:.spec.template.spec.affinity,TOLERATIONS:.spec.template.spec.tolerations,PRIORITYCLASS:.spec.template.spec.priorityClassName'
WL="$(kubectl get deploy,statefulset,daemonset -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.nodeSelector}{.spec.template.spec.affinity}{.spec.template.spec.tolerations}{.spec.template.spec.priorityClassName}{"\n"}{end}')"
WL_TOT="$(printf '%s\n' "$WL" | grep -c . || true)"
WL_FREE="$(printf '%s\n' "$WL" | awk -F'\t' 'NF && $2 == ""' | wc -l | tr -d ' ')"
echo "Workload senza alcun vincolo di collocazione o priorita': $WL_FREE su $WL_TOT"

# -----------------------------------------------------------------------------
line "2. Nodo: il control plane respinge i pod applicativi (taint)?"
kubectl get nodes -o custom-columns='NODE:.metadata.name,CONTROL-PLANE:.metadata.labels.node-role\.kubernetes\.io/control-plane,TAINTS:.spec.taints[*].key'
CP_UNTAINTED=0
for n in $CP_NODES; do
  t="$(taints_of "$n")"
  case " $t" in
    *" $CP_KEY:NoSchedule "*|*" $CP_KEY:NoExecute "*) echo "$n: taint del control plane presente" ;;
    *) echo "$n: NESSUN taint del control plane (taint presenti: ${t:-nessuno})"
       CP_UNTAINTED=$((CP_UNTAINTED + 1)) ;;
  esac
done

# -----------------------------------------------------------------------------
line "3. Admission: esiste una policy che vieti i pod sul control plane?"
echo "-- ValidatingAdmissionPolicy e binding (API nativa, GA da Kubernetes 1.30):"
kubectl get validatingadmissionpolicies,validatingadmissionpolicybindings 2>&1 || true
VAP_N="$(kubectl get validatingadmissionpolicies -o name 2>/dev/null | grep -c . || true)"
echo "-- Webhook di admission e risorse che intercettano:"
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,RESOURCES:.webhooks[*].rules[*].resources' 2>&1 || true
POD_HOOKS="$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.webhooks[*].rules[*].resources}{"\n"}{end}' 2>/dev/null \
  | grep -E '"pods"|"\*"' | awk '{print $1}' | tr '\n' ' ' || true)"
echo "Webhook che intercettano i pod: ${POD_HOOKS:-nessuno}"
echo "-- Motori di policy (Kyverno, Gatekeeper):"
ENGINES="$(kubectl get crd -o name 2>/dev/null | grep -E 'kyverno\.io|gatekeeper\.sh' | tr '\n' ' ' || true)"
echo "${ENGINES:-nessuno installato}"

# -----------------------------------------------------------------------------
line "4. Namespace: quote, limiti e priorita' che proteggano il control plane?"
kubectl get resourcequota,limitrange -n "$NS" 2>&1 || true
QUOTA_N="$(kubectl get resourcequota,limitrange -n "$NS" -o name 2>/dev/null | grep -c . || true)"
echo "-- Priorita' dei pod dello stack (numero di pod per valore):"
kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.spec.priority}{"\n"}{end}' | sort | uniq -c
echo "-- Priorita' dei componenti del control plane:"
kubectl get pods -n kube-system \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,PRIORITY:.spec.priority,CLASS:.spec.priorityClassName' \
  | grep -E '^POD|etcd|apiserver|controller-manager|scheduler' || true

# -----------------------------------------------------------------------------
line "5. Esito: su quale nodo girano i pod dello stack?"
PODS="$(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\n"}{end}')"
printf '%s\n' "$PODS"
POD_TOT="$(printf '%s\n' "$PODS" | grep -c . || true)"
POD_CP=0
for n in $CP_NODES; do
  c="$(printf '%s\n' "$PODS" | awk -F'\t' -v n="$n" '$2 == n' | wc -l | tr -d ' ')"
  POD_CP=$((POD_CP + c))
done
echo "Pod dello stack su un nodo del control plane: $POD_CP su $POD_TOT"

# -----------------------------------------------------------------------------
if [ "$LAB" = "1" ]; then
  TAINTED=""
  cleanup() {
    set +e
    kubectl delete pod -n "$NS" -l "app.kubernetes.io/name=$LAB_NAME" \
      --ignore-not-found --grace-period=0 >/dev/null 2>&1
    for n in $TAINTED; do
      kubectl taint nodes "$n" "$CP_KEY:NoSchedule-" >/dev/null 2>&1 \
        && echo "(pulizia: taint rimosso da $n)"
    done
    kubectl delete validatingadmissionpolicybinding "$LAB_NAME" --ignore-not-found >/dev/null 2>&1
    kubectl delete validatingadmissionpolicy "$LAB_NAME" --ignore-not-found >/dev/null 2>&1
    echo "(pulizia: pod e policy di laboratorio rimossi)"
  }
  trap cleanup EXIT

  # Pod "pause" minimale. Con $2 = cp chiede esplicitamente il control plane.
  lab_pod() {
    cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels:
    app.kubernetes.io/name: $LAB_NAME
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  containers:
  - name: pause
    image: $PAUSE_IMAGE
    imagePullPolicy: IfNotPresent
    resources:
      requests: { cpu: 10m, memory: 16Mi }
      limits: { cpu: 50m, memory: 32Mi }
    securityContext:
      runAsNonRoot: true
      runAsUser: 65535
      allowPrivilegeEscalation: false
      capabilities: { drop: [ALL] }
EOF
    if [ "${2:-}" = "cp" ]; then
      cat <<EOF
  nodeSelector:
    $CP_KEY: ""
  tolerations:
  - key: $CP_KEY
    operator: Exists
    effect: NoSchedule
EOF
    fi
  }

  line "6. [LAB] Un pod che chiede esplicitamente il control plane e' accettato?"
  echo "-- Admission (dry-run lato server, non crea nulla):"
  lab_pod misconfig2-cp cp | kubectl apply --dry-run=server -f - 2>&1 || true
  echo "-- Scheduling reale: un pod senza vincoli (come quelli del chart) e uno che chiede il control plane"
  lab_pod misconfig2-free | kubectl apply -f -
  lab_pod misconfig2-cp cp | kubectl apply -f -
  kubectl wait pod -n "$NS" -l "app.kubernetes.io/name=$LAB_NAME" --for=condition=Ready --timeout=120s || true
  kubectl get pods -n "$NS" -l "app.kubernetes.io/name=$LAB_NAME" \
    -o custom-columns='POD:.metadata.name,STATO:.status.phase,NODE:.spec.nodeName'
  kubectl delete pod -n "$NS" -l "app.kubernetes.io/name=$LAB_NAME" --grace-period=0 --wait=true >/dev/null 2>&1 || true

  if [ "$POLICY" = "1" ]; then
    line "7. [LAB] Le stesse richieste con le policy mancanti applicate"
    for n in $CP_NODES; do
      if taints_of "$n" | grep -q "$CP_KEY:NoSchedule"; then
        echo "$n: taint gia' presente, non lo tocco"
      else
        kubectl taint nodes "$n" "$CP_KEY=:NoSchedule" && TAINTED="$TAINTED $n"
      fi
    done
    kubectl apply -f - <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: $LAB_NAME
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE"]
      resources: ["pods"]
  validations:
  - expression: >-
      !has(object.spec.tolerations) ||
      !object.spec.tolerations.exists(t,
        (has(t.key) && t.key == '$CP_KEY') ||
        (!has(t.key) && has(t.operator) && t.operator == 'Exists'))
    message: "i pod applicativi non possono tollerare il taint del control plane"
  - expression: >-
      !has(object.spec.nodeSelector) ||
      !('$CP_KEY' in object.spec.nodeSelector)
    message: "i pod applicativi non possono chiedere il nodo del control plane"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: $LAB_NAME
spec:
  policyName: $LAB_NAME
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: $NS
EOF
    echo "-- Admission del pod che chiede il control plane (atteso: rifiutato dalla policy):"
    OUT=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do   # la policy diventa attiva entro pochi secondi
      OUT="$(lab_pod misconfig2-cp cp | kubectl apply --dry-run=server -f - 2>&1 || true)"
      case "$OUT" in *denied*|*"$LAB_NAME"*) break ;; esac
      sleep 2
    done
    echo "$OUT"
    echo "-- Scheduling del pod senza vincoli (atteso: Pending per il taint):"
    lab_pod misconfig2-free | kubectl apply -f -
    sleep 15
    kubectl get pod misconfig2-free -n "$NS" \
      -o custom-columns='POD:.metadata.name,STATO:.status.phase,NODE:.spec.nodeName'
    kubectl get events -n "$NS" --field-selector involvedObject.name=misconfig2-free,reason=FailedScheduling \
      -o custom-columns='MOTIVO:.reason,MESSAGGIO:.message' 2>&1 || true
  fi
fi

# -----------------------------------------------------------------------------
echo
echo "RIEPILOGO"
echo "  workload senza vincoli di collocazione o priorita': $WL_FREE su $WL_TOT"
echo "  nodi control plane senza taint:                    $CP_UNTAINTED su $CP_COUNT"
echo "  ValidatingAdmissionPolicy nel cluster:              $VAP_N"
echo "  webhook che intercettano i pod:                     ${POD_HOOKS:-nessuno}"
echo "  motori di policy (Kyverno/Gatekeeper):              ${ENGINES:-nessuno}"
echo "  ResourceQuota/LimitRange nel namespace:             $QUOTA_N"
echo "  pod dello stack sul nodo del control plane:         $POD_CP su $POD_TOT"
echo
echo "CONCLUSIONE: se tutti i contatori di policy sono a zero, nessun livello"
echo "(chart, nodo, admission, namespace) impedisce ai workload di finire sul"
echo "control plane: la co-locazione non e' una scelta, e' l'esito predefinito."
