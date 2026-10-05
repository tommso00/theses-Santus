#!/bin/sh
# Scrive nel PVC del Backend la configurazione OSGi gestita dal chart
# (ConfigMap openems-backend-config, montata in /bootstrap).
# I componenti facoltativi (storico InfluxDB, API Backend2Backend) vengono
# aggiunti o tolti in base ai file presenti nella ConfigMap.
set -eu
C=/var/opt/openems/config

# put <file della ConfigMap> <percorso relativo nel PVC>
put() {
  mkdir -p "$C/$(dirname "$2")"
  cp "/bootstrap/$1" "$C/$2"
  chmod 0644 "$C/$2"
}

put Edge.Websocket.config Edge/Websocket.config
put Ui.Websocket.config   Ui/Websocket.config
put Metadata.File.config  Metadata/File.config
put metadata.json         metadata.json
echo "Edge registrati nel Backend:"
grep -oE '^ *"edge[0-9]+": *\{' "$C/metadata.json" | tr -d ' "{:' | sed 's/^/  - /'

# Storico: InfluxDB se abilitato, altrimenti Timedata.Dummy (come l'immagine ufficiale).
rm -f "$C/Timedata/Dummy.config" "$C/Timedata/InfluxDB/timedata0.config"
if [ -f /bootstrap/Timedata.InfluxDB.config ]; then
  mkdir -p "$C/Timedata/InfluxDB"
  # Il token arriva dal Secret: non è scritto nella ConfigMap.
  sed "s|__INFLUXDB_TOKEN__|${INFLUXDB_TOKEN}|" /bootstrap/Timedata.InfluxDB.config \
    > "$C/Timedata/InfluxDB/timedata0.config"
  chmod 0600 "$C/Timedata/InfluxDB/timedata0.config"
  echo "Timedata: InfluxDB"
else
  put Timedata.Dummy.config Timedata/Dummy.config
  echo "Timedata: Dummy (nessuno storico)"
fi

# API Backend2Backend REST
rm -f "$C/Backend2Backend/Rest/b2brest0.config"
if [ -f /bootstrap/Backend2Backend.Rest.config ]; then
  put Backend2Backend.Rest.config Backend2Backend/Rest/b2brest0.config
  echo "Backend2Backend REST: attiva"
fi
