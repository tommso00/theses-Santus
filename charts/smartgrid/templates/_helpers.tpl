{{/* =========================================================================
     Helper comuni del chart smartgrid
     ========================================================================= */}}

{{/*
Etichette standard di una risorsa.
Parametri (dict):
  root       contesto principale ($)
  app        nome del componente: diventa l'etichetta "app", usata da selector e NetworkPolicy
  component  gruppo funzionale (auth, openems, pmu, timedata)
  role       (opzionale) smartgrid.io/role: openems-edge, openpdc, pmu-bridge, ...
  edge       (opzionale) smartgrid.io/edge: Edge a cui appartiene la risorsa
  pod        (opzionale) true per i pod: niente etichetta di versione del chart,
             così un aggiornamento del chart non riavvia tutti i pod
*/}}
{{- define "smartgrid.labels" -}}
app: {{ .app }}
app.kubernetes.io/name: {{ .app }}
app.kubernetes.io/component: {{ .component }}
app.kubernetes.io/part-of: smartgrid
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- if not .pod }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version | replace "+" "_" }}
{{- end }}
environment: {{ .root.Values.global.environment }}
{{- with .role }}
smartgrid.io/role: {{ . }}
{{- end }}
{{- with .edge }}
smartgrid.io/edge: {{ . }}
{{- end }}
{{- end }}

{{/* Riferimento completo a un'immagine: (dict "root" $ "name" "openemsEdge") */}}
{{- define "smartgrid.image" -}}
{{- $img := index .root.Values.images .name -}}
image: {{ printf "%s:%s" $img.repository $img.tag | quote }}
imagePullPolicy: {{ .root.Values.images.pullPolicy }}
{{- end }}

{{/* Variabile d'ambiente letta dal Secret delle credenziali: (dict "root" $ "name" "VAR" "key" "CHIAVE") */}}
{{- define "smartgrid.secretEnv" -}}
- name: {{ .name }}
  valueFrom:
    secretKeyRef:
      name: {{ .root.Values.global.existingSecret }}
      key: {{ .key }}
{{- end }}

{{/* initContainer che aspetta una porta TCP: (dict "root" $ "name" "wait-x" "host" "h" "port" 1234) */}}
{{- define "smartgrid.waitFor" -}}
- name: {{ .name }}
  {{- include "smartgrid.image" (dict "root" .root "name" "busybox") | nindent 2 }}
  command: ["sh", "-c", {{ printf "until nc -z -w 2 %s %v; do echo 'attendo %s:%v...'; sleep 2; done" .host .port .host .port | quote }}]
{{- end }}

{{/* Annotazione per i PVC: helm uninstall non cancella i dati. */}}
{{- define "smartgrid.keepPvc" -}}
helm.sh/resource-policy: keep
{{- end }}

{{/*
Topologia normalizzata (JSON): Edge con i valori di default applicati e le loro
pipeline PMU numerate. È l'unico punto che interpreta "edges", "edgeDefaults" e
"pmuDefaults": tutti i template la leggono con
  {{ $topo := include "smartgrid.topology" . | fromJson }}
Controlla anche ciò che lo schema JSON non può esprimere (ID e apikey unici).
I numeri tornano come float64: nei template si stampano con "int".
*/}}
{{- define "smartgrid.topology" -}}
{{- $root := . -}}
{{- $edges := list -}}
{{- $ids := dict -}}
{{- $keys := dict -}}
{{- $pdcId := 0 -}}
{{- range $e := .Values.edges -}}
  {{- if hasKey $ids $e.id -}}
    {{- fail (printf "edges: l'id %q compare più volte" $e.id) -}}
  {{- end -}}
  {{- $_ := set $ids $e.id true -}}
  {{- $apikey := default $e.id $e.apikey -}}
  {{- if hasKey $keys $apikey -}}
    {{- fail (printf "edges: l'apikey %q è usata da più Edge" $apikey) -}}
  {{- end -}}
  {{- $_ := set $keys $apikey true -}}

  {{- $pmuList := list -}}
  {{- if kindIs "slice" $e.pmu -}}
    {{- $pmuList = $e.pmu -}}
  {{- else -}}
    {{- range until (int (default 0 $e.pmu)) -}}
      {{- $pmuList = append $pmuList (dict) -}}
    {{- end -}}
  {{- end -}}

  {{- $pipelines := list -}}
  {{- range $i, $raw := $pmuList -}}
    {{- $p := default (dict) $raw -}}
    {{- $pdcId = add1 $pdcId -}}
    {{- $n := add1 $i -}}
    {{- $env := mergeOverwrite (deepCopy $root.Values.pmuDefaults.bridge.env) (deepCopy (dig "bridge" "env" (dict) $p)) -}}
    {{- $pipelines = append $pipelines (dict
          "index" $n
          "pdcId" $pdcId
          "pdc" (printf "pdc-%s-%d" $e.id $n)
          "bridge" (printf "bridge-%s-%d" $e.id $n)
          "env" $env
          "bridgeResources" (dig "bridge" "resources" $root.Values.pmuDefaults.bridge.resources $p)
          "pdcStorage" (dig "pdc" "storage" $root.Values.pmuDefaults.pdc.storage $p)
          "pdcResources" (dig "pdc" "resources" $root.Values.pmuDefaults.pdc.resources $p)) -}}
  {{- end -}}

  {{- $edges = append $edges (dict
        "id" $e.id
        "name" (printf "openems-%s" $e.id)
        "comment" (default $e.id $e.comment)
        "apikey" $apikey
        "simulator" (mergeOverwrite (deepCopy $root.Values.edgeDefaults.simulator) (deepCopy (default (dict) $e.simulator)))
        "pipelines" $pipelines) -}}
{{- end -}}
{{- toJson (dict "edges" $edges) -}}
{{- end }}

{{/*
File di configurazione OSGi di un Edge, scritti nel suo PVC a ogni avvio.
Parametri: (dict "root" $ "edge" <Edge della topologia>)
*/}}
{{- define "smartgrid.edgeConfig" -}}
{{- $e := .edge -}}
{{- $s := $e.simulator -}}
{{- $timeout := int .root.Values.edgeDefaults.apiTimeout -}}
backend0.config: |
  enabled=B"true"
  uri="ws://openems-backend:8081"
  apikey="{{ $e.apikey }}"
  apiTimeout=I"{{ $timeout }}"
  id="ctrlBackend0"
  service.factoryPid="Controller.Api.Backend"
  service.pid="Controller.Api.Backend.backend0"
websocket0.config: |
  alias=""
  apiTimeout=I"{{ $timeout }}"
  enabled=B"true"
  id="ctrlApiWebsocket0"
  port=I"8085"
  service.factoryPid="Controller.Api.Websocket"
  service.pid="Controller.Api.Websocket.websocket0"
rest0.config: |
  enabled=B"true"
  port=I"8084"
  service.pid="Controller.Api.Rest.ReadWrite.rest0"
  service.factoryPid="Controller.Api.Rest.ReadWrite"
  id="ctrlApiRest0"
  alias=""
  apiTimeout=I"{{ $timeout }}"
  debugMode=B"false"
datasource0.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  alias="Datasource Load H0"
  enabled=B"true"
  id="datasource0"
  factor=F"{{ include "smartgrid.floatBits" $s.loadFactor }}"
  timeDelta=I"-1"
  source="{{ $s.loadProfile }}"
  format="GERMAN_EXCEL"
  service.factoryPid="Simulator.Datasource.CSV.Predefined"
  service.pid="Simulator.Datasource.CSV.Predefined.datasource0"
meter0.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  alias="Simulator.GridMeter.Acting"
  enabled=B"true"
  id="meter0"
  datasource.id="datasource0"
  minPower=I"-100000"
  maxPower=I"100000"
  service.factoryPid="Simulator.GridMeter.Acting"
  service.pid="Simulator.GridMeter.Acting.meter0"
ess0.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  alias="Simulator.EssAsymmetric.Reacting"
  enabled=B"true"
  id="ess0"
  maxApparentPower=I"{{ int $s.maxApparentPower }}"
  capacity=I"{{ int $s.capacity }}"
  initialSoc=I"{{ int $s.initialSoc }}"
  gridMode="ON_GRID"
  service.factoryPid="Simulator.EssAsymmetric.Reacting"
  service.pid="Simulator.EssAsymmetric.Reacting.ess0"
debuglog0.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  alias="Controller.Debug.Log"
  enabled=B"true"
  id="ctrlDebugLog0"
  interval=I"10"
  service.factoryPid="Controller.Debug.Log"
  service.pid="Controller.Debug.Log.ctrlDebugLog0"
balancing0.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  alias="Controller.Symmetric.Balancing"
  enabled=B"true"
  id="ctrlBalancing0"
  ess.id="ess0"
  meter.id="meter0"
  targetGridSetpoint=I"0"
  service.factoryPid="Controller.Symmetric.Balancing"
  service.pid="Controller.Symmetric.Balancing.ctrlBalancing0"
{{- /* Priorità dei setpoint su ess0: nello stesso ciclo vince il PRIMO controller
       che scrive (gli altri vanno in conflitto e lo segnalano nei log).
         1. ctrlBackend0   comando dal Backend (API Backend2Backend): override dell'operatore
         2. ctrlApiRest0   setpoint dei bridge PMU
         3. ctrlBalancing0 bilanciamento, quando nessuno dei due scrive */}}
scheduler0.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  alias="Scheduler.AllAlphabetically"
  enabled=B"true"
  id="scheduler0"
  controllers.ids=[ \
    "ctrlBackend0", \
    "ctrlApiRest0", \
    "ctrlApiWebsocket0", \
    "ctrlBalancing0", \
    "ctrlDebugLog0" \
  ]
  service.factoryPid="Scheduler.AllAlphabetically"
  service.pid="Scheduler.AllAlphabetically.scheduler0"
{{- end }}

{{/*
Configurazione OSGi del Backend (chiavi della ConfigMap openems-backend-config).
Il token di InfluxDB non è qui: lo inserisce l'initContainer leggendo il Secret.
*/}}
{{- define "smartgrid.backendConfig" -}}
{{- $topo := include "smartgrid.topology" . | fromJson -}}
{{- $influx := .Values.timedata.influxdb -}}
Edge.Websocket.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  poolSize=I"10"
  port=I"8081"
  service.pid="Edge.Websocket"
Ui.Websocket.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  poolSize=I"10"
  port=I"8082"
  service.pid="Ui.Websocket"
Metadata.File.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  path="/var/opt/openems/config/metadata.json"
  service.pid="Metadata.File"
metadata.json: |
  {
    "edges": {
  {{- range $i, $e := $topo.edges }}
      {{ $e.id | toJson }}: {
        "comment": {{ $e.comment | toJson }},
        "apikey": {{ $e.apikey | toJson }}
      }{{ if lt (add1 $i) (len $topo.edges) }},{{ end }}
  {{- end }}
    }
  }
{{- if .Values.timedata.enabled }}
Timedata.InfluxDB.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  id="timedata0"
  url="http://influxdb:8086"
  org="{{ $influx.org }}"
  apiKey="__INFLUXDB_TOKEN__"
  bucket="{{ $influx.bucket }}"
  measurement="data"
  queryLanguage="INFLUX_QL"
  isReadOnly=B"false"
  poolSize=I"10"
  maxQueueSize=I"5000"
  service.factoryPid="Timedata.InfluxDB"
  service.pid="Timedata.InfluxDB.timedata0"
{{- else }}
Timedata.Dummy.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  id="timedata0"
  service.pid="Timedata.Dummy"
{{- end }}
{{- if .Values.backend.b2bRest.enabled }}
Backend2Backend.Rest.config: |
  :org.apache.felix.configadmin.revision:=L"1"
  port=I"{{ int .Values.backend.b2bRest.port }}"
  service.factoryPid="Backend2Backend.Rest"
  service.pid="Backend2Backend.Rest.b2brest0"
{{- end }}
{{- end }}

{{/*
Valore float per i file .config di OpenEMS. Felix ConfigAdmin (1.9.x, usato da
OpenEMS) legge F"..." come i BIT IEEE-754 del float (Float.intBitsToFloat), non
come numero decimale: F"10000" varrebbe 1.4e-45 * 10000, cioè quasi zero.
Questo helper calcola i bit per un intero tra 0 e 2^24 (rappresentato esattamente).
Uso: F"{{ include "smartgrid.floatBits" 10000 }}"  ->  F"1176256512"
*/}}
{{- define "smartgrid.floatBits" -}}
{{- $n := int . -}}
{{- if eq $n 0 -}}
0
{{- else -}}
{{- $e := 0 -}}
{{- $p := 1 -}}
{{- range until 24 -}}
  {{- if le (mul $p 2) $n -}}
    {{- $p = mul $p 2 -}}
    {{- $e = add1 $e -}}
  {{- end -}}
{{- end -}}
{{- $scale := 1 -}}
{{- range until (sub 23 $e | int) -}}
  {{- $scale = mul $scale 2 -}}
{{- end -}}
{{- add (mul (add 127 $e) 8388608) (mul (sub $n $p) $scale) -}}
{{- end -}}
{{- end }}
