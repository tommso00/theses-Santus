#!/usr/bin/env bash
# =============================================================================
# Misconfig 3 - Helm allows secret name override (STRIDE riga 19)
#
# Mostra che: il nome del Secret da cui TUTTI i componenti leggono le credenziali
# e' il valore libero global.existingSecret. Con un solo --set si puo' puntare il
# chart a un Secret arbitrario del namespace, iniettando credenziali scelte
# dall'attaccante (es. un client secret noto, un token InfluxDB controllato).
#
# Questo test NON richiede un cluster: usa solo "helm template" per confrontare
# i manifest renderizzati. Esegue il chart di questo repository.
#
# Uso:   ./03-helm-secret-override.sh [percorso-del-chart]
#        (default: cerca charts/smartgrid salendo dalle cartelle)
# =============================================================================
set -euo pipefail

CHART="${1:-}"
if [ -z "$CHART" ]; then
  d="$(cd "$(dirname "$0")" && pwd)"
  while [ "$d" != "/" ]; do
    [ -f "$d/charts/smartgrid/Chart.yaml" ] && CHART="$d/charts/smartgrid" && break
    d="$(dirname "$d")"
  done
fi
[ -n "$CHART" ] && [ -f "$CHART/Chart.yaml" ] || { echo "chart non trovato: passare il percorso di charts/smartgrid"; exit 1; }
command -v helm >/dev/null || { echo "serve helm nel PATH"; exit 1; }

line() { printf '\n=== %s\n' "$1"; }
EVIL="attacker-controlled-secret"

line "1. Con i valori di default: da quale Secret leggono i componenti?"
echo "-- i secretKeyRef nei manifest renderizzati:"
helm template smartgrid "$CHART" | grep -E 'secretKeyRef' -A1 | grep -E 'name:' | sort | uniq -c
echo "-- conteggio dei riferimenti al Secret di default (auth-secrets):"
helm template smartgrid "$CHART" | grep -c 'name: auth-secrets' || true

line "2. Un attaccante con accesso a Helm punta il chart a un Secret suo:"
echo "   helm upgrade smartgrid $CHART --set global.existingSecret=$EVIL"
echo "-- nei manifest ora i secretKeyRef puntano a '$EVIL':"
helm template smartgrid "$CHART" --set "global.existingSecret=$EVIL" \
  | grep -E 'secretKeyRef' -A2 | grep -E "name: $EVIL" | sort | uniq -c
echo "-- conteggio dei riferimenti al Secret dell'attaccante:"
helm template smartgrid "$CHART" --set "global.existingSecret=$EVIL" | grep -c "name: $EVIL" || true

line "3. Lo schema dei valori impedisce il cambio?"
echo "   values.schema.json impone solo 'type: string, minLength: 1' su existingSecret:"
grep -n 'existingSecret' -A3 "$CHART/values.schema.json" || true
echo "   -> nessun vincolo sul nome: qualsiasi Secret del namespace e' accettato."

echo
echo "CONCLUSIONE: Keycloak, OAuth2 Proxy, InfluxDB e i bridge leggono le credenziali"
echo "dal Secret indicato in global.existingSecret. Chi puo' fare 'helm upgrade' (o"
echo "modificare i values in un repo GitOps) sostituisce quel Secret e inietta"
echo "credenziali note, ad es. un OAUTH2_PROXY_CLIENT_SECRET scelto da lui."
