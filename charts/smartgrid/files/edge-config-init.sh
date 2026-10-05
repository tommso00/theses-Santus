#!/bin/sh
# Scrive nel PVC dell'Edge la configurazione OSGi gestita dal chart
# (ConfigMap openems-<id>-config, montata in /init-config).
# I manifest sono la fonte della verità: a ogni avvio i file vengono riscritti.
#
# Il ConfigAdmin di Felix carica un file solo se il suo percorso corrisponde al
# service.pid che contiene (i punti diventano cartelle):
#   Controller.Debug.Log.ctrlDebugLog0 -> Controller/Debug/Log/ctrlDebugLog0.config
# Un file in un altro percorso viene ignorato in silenzio, quindi il percorso
# non si scrive a mano: si ricava dal service.pid del file.
set -eu
C=/var/opt/openems/config
MANAGED=""

# pid_path <file della ConfigMap>: percorso relativo nel PVC, dal service.pid
pid_path() {
  pid=$(sed -n 's/^service\.pid="\(.*\)"$/\1/p' "/init-config/$1")
  if [ -z "$pid" ]; then
    echo "ERRORE: service.pid mancante in $1" >&2
    exit 1
  fi
  printf '%s.config\n' "$(printf '%s' "$pid" | tr . /)"
}

# install_cfg <file della ConfigMap>
install_cfg() {
  rel=$(pid_path "$1")
  mkdir -p "$C/$(dirname "$rel")"
  cp "/init-config/$1" "$C/$rel"
  MANAGED="$MANAGED $rel"
  echo "  $1 -> $rel"
}

# File scritti dalle versioni precedenti in percorsi che Felix non legge
# (e "Controller.Api.Rest", componente inesistente).
rm -f "$C/Controller/Api/Rest/rest0.config" \
      "$C/Simulator/Datasource/CSVPredefined/datasource0.config" \
      "$C/Controller/DebugLog/debuglog0.config" \
      "$C/Controller/Ess/Balancing/balancing0.config"
rmdir "$C/Simulator/Datasource/CSVPredefined" "$C/Controller/DebugLog" \
      "$C/Controller/Ess/Balancing" "$C/Controller/Ess" 2>/dev/null || true

echo "Configurazione gestita:"
install_cfg backend0.config
install_cfg websocket0.config

REST_REL=$(pid_path rest0.config)
REST_DIR="$C/$(dirname "$REST_REL")"
mkdir -p "$REST_DIR"
OTHER_REST=$(find "$REST_DIR" -name '*.config' ! -name "$(basename "$REST_REL")" | head -n 1)
if [ -n "$OTHER_REST" ]; then
  # Esiste già un controller REST creato a mano (es. dalla UI): non ne creo
  # un secondo sulla stessa porta 8084.
  echo "REST ReadWrite già presente ($OTHER_REST): salto la creazione di rest0"
else
  install_cfg rest0.config
fi

install_cfg datasource0.config
install_cfg meter0.config
install_cfg ess0.config
install_cfg debuglog0.config
install_cfg balancing0.config
install_cfg scheduler0.config

# Una configurazione con lo stesso id di un componente gestito (es. creata dalla
# UI) manda OpenEMS in FAULT "duplicated Component-IDs": la rimuovo.
cd "$C"
for f in $MANAGED; do
  [ -f "$f" ] || continue
  idline=$(grep -m1 '^id=' "$f") || continue
  find . -name '*.config' | while read -r g; do
    [ "$g" = "./$f" ] && continue
    if grep -qxF "$idline" "$g"; then
      echo "Rimuovo configurazione duplicata ($idline): $g"
      rm -f "$g"
    fi
  done
done

chown -R 911:911 "$C"
chmod -R u+rwX,go+rX "$C"
echo "Configurazione dell'Edge scritta in $C"