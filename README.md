# Smart Grid Kubernetes

Progetto Smart Grid distribuito su Kubernetes tramite Minikube, con deployment locale dei componenti OpenEMS, autenticazione Keycloak/OAuth2 Proxy, servizi WebProxy/Nginx, Odoo, Redis e pipeline PMU/openPDC.

## Componenti principali

- OpenEMS Edge
- OpenEMS Backend
- OpenEMS UI e UI Backend
- Keycloak e PostgreSQL
- OAuth2 Proxy
- WebProxy/Nginx
- Odoo e PostgreSQL
- Redis
- PMU bridges
- openPDC / pdc-edge

## Requisiti

- Windows con PowerShell
- Docker Desktop
- Minikube
- kubectl
- Kustomize, normalmente incluso in `kubectl`
- Risorse sufficienti per Minikube per eseguire tutti i componenti
- Configurazione locale dell'hostname:
  - `smartgrid.local`
  - risolto verso l'IP del nodo Minikube tramite file `hosts` o meccanismo equivalente

Esempio di verifica degli strumenti:

```powershell
minikube version
kubectl version --client
kubectl kustomize --help
```

## Struttura del progetto

```text
k8s/
├── base/
│   ├── apps/
│   ├── auth/
│   ├── openems/
│   ├── pvc/
│   ├── configmaps.yaml
│   ├── namespace.yaml
│   └── kustomization.yaml
├── openems-edge-config/
├── overlays/
│   ├── minikube/
│   ├── staging/
│   └── prod/
└── rendered-minikube.yaml
```

L'ambiente Minikube viene costruito dall'overlay:

```text
k8s/overlays/minikube/
```

## Avvio del progetto

### 1. Avviare Minikube

Esempio:

```powershell
minikube start
```

Verificare il nodo:

```powershell
kubectl get nodes
```

### 2. Creare o verificare il namespace

Il namespace previsto è:

```text
smartgrid
```

Verificare le risorse:

```powershell
kubectl get namespace smartgrid
```

### 3. Applicare la configurazione Minikube

Dalla directory del progetto:

```powershell
cd D:\Prj_4-backup\k8s
kubectl apply -k .\overlays\minikube
```

Per visualizzare il manifest renderizzato senza applicarlo:

```powershell
kubectl kustomize .\overlays\minikube > .\rendered-minikube.yaml
```

### 4. Controllare lo stato del cluster

```powershell
kubectl get pods -n smartgrid -o wide
kubectl get svc -n smartgrid
kubectl get pvc -n smartgrid
kubectl get deployments -n smartgrid
```

Attendere che i pod principali risultino `Running` e `READY 1/1`.

### 5. Configurare l'accesso a `smartgrid.local`

Recuperare l'IP Minikube:

```powershell
minikube ip
```

Aggiungere una voce al file hosts di Windows con privilegi amministrativi:

```text
<MINIKUBE_IP> smartgrid.local
```

Il file si trova normalmente in:

```text
C:\Windows\System32\drivers\etc\hosts
```

Verificare la risoluzione:

```powershell
ping smartgrid.local
```

### 6. Accedere ai servizi

URL principale:

```text
http://smartgrid.local
```

Login Keycloak:

```text
http://smartgrid.local/auth/realms/openems/
```

Callback OAuth2 Proxy:

```text
http://smartgrid.local/oauth2/callback
```

Endpoint di monitoraggio WebProxy:

```text
http://smartgrid.local/monitor/
```

## Configurazione autenticazione

Il flusso di autenticazione è composto da:

```text
Browser
  → WebProxy/Nginx
  → OAuth2 Proxy
  → Keycloak realm openems
  → OAuth2 callback
  → sessione OAuth2 Proxy su Redis
```

Il client Keycloak usato da OAuth2 Proxy è:

```text
openems-gateway
```

Il redirect URI previsto è:

```text
http://smartgrid.local/oauth2/callback
```

I secret sono definiti in:

```text
k8s/base/auth/secrets.yaml
```

Non inserire secret reali in Git o in ConfigMap. Se un secret viene condiviso accidentalmente, deve essere ruotato.

## Persistenza

Il database Keycloak deve utilizzare il PVC:

```text
keycloak-db-data
```

Prima di considerare la persistenza funzionante, verificare che il Deployment PostgreSQL contenga entrambi:

```yaml
volumeMounts:
  - name: keycloak-db-data
    mountPath: /var/lib/postgresql/data

volumes:
  - name: keycloak-db-data
    persistentVolumeClaim:
      claimName: keycloak-db-data
```

La sola presenza di un PVC `Bound` non garantisce che PostgreSQL lo stia utilizzando.

Verifica:

```powershell
kubectl get pvc -n smartgrid
kubectl get deployment keycloak-db -n smartgrid -o yaml
```

Non cancellare il PVC `keycloak-db-data` durante le operazioni di manutenzione.

## Diagnostica

### Pod

```powershell
kubectl get pods -n smartgrid -o wide
kubectl describe pod -n smartgrid <POD_NAME>
```

### Log principali

```powershell
kubectl logs -n smartgrid deployment/keycloak --tail=200
kubectl logs -n smartgrid deployment/keycloak-db --tail=200
kubectl logs -n smartgrid deployment/oauth2-proxy --tail=200
kubectl logs -n smartgrid deployment/webproxy --tail=200
```

### Eventi Kubernetes

```powershell
kubectl get events -n smartgrid --sort-by=.lastTimestamp
```

### Diagnostica OAuth2 Proxy

Per errori durante il callback:

```powershell
kubectl logs -n smartgrid deployment/oauth2-proxy --since=10m --timestamps |
  Select-String -Pattern "callback|redeem|unauthorized|invalid|error|session|redis"
```

Un errore come:

```text
unauthorized_client
Invalid client or Invalid client credentials
```

indica normalmente un problema nel client secret, nel client ID o nella configurazione del client OIDC.

### Configurazione realmente applicata

Confrontare sempre i file sorgente con il cluster:

```powershell
kubectl get deployment keycloak -n smartgrid -o yaml
kubectl get deployment keycloak-db -n smartgrid -o yaml
kubectl get deployment oauth2-proxy -n smartgrid -o yaml
kubectl get deployment webproxy -n smartgrid -o yaml
```

## Aggiornare un Secret usato come variabile d'ambiente

Dopo aver modificato `k8s/base/auth/secrets.yaml`, applicare solo il Secret di autenticazione:

```powershell
kubectl apply -f .\base\auth\secrets.yaml
```

Riavviare poi solo OAuth2 Proxy:

```powershell
kubectl rollout restart deployment/oauth2-proxy -n smartgrid
kubectl rollout status deployment/oauth2-proxy -n smartgrid --timeout=120s
```

Evitare di applicare l'intero overlay per una modifica limitata all'autenticazione, salvo quando è intenzionale aggiornare tutto lo stack.

## Stop e riavvio

Per sospendere Minikube:

```powershell
minikube stop
```

Per riavviarlo:

```powershell
minikube start
kubectl get pods -n smartgrid
```

Non cancellare il profilo Minikube se si vuole conservare lo storage locale:

```powershell
# Comando distruttivo: usare solo intenzionalmente
minikube delete
```

## Tracciamento progressi

### Completato

- [x] Deployment dello stack Smart Grid su Minikube.
- [x] Namespace `smartgrid` configurato.
- [x] OpenEMS Edge funzionante con immagine `openems/edge:2025.1.0`.
- [x] Configurazione OpenEMS inizializzata tramite PVC scrivibile e initContainer.
- [x] WebProxy/Nginx configurato per il routing dei servizi.
- [x] Keycloak configurato con realm `openems`.
- [x] Utente di test `testuser` verificato.
- [x] Client Keycloak `openems-gateway` identificato.
- [x] OAuth2 Proxy configurato con issuer, callback e Redis.
- [x] Errore `500` analizzato nei log OAuth2 Proxy.
- [x] Causa del `500` identificata: client secret non corrispondente.
- [x] Client secret aggiornato in Keycloak e nel file `base/auth/secrets.yaml`.
- [x] Backup PostgreSQL creato prima della correzione.
- [x] PVC `keycloak-db-data` collegato al Deployment `keycloak-db`.
- [x] PostgreSQL ha rilevato il database esistente e ha saltato l'inizializzazione.
- [x] Keycloak ha mantenuto il realm `openems` con strategia `IGNORE_EXISTING`.
- [x] Login OAuth2 verificato dopo la persistenza PostgreSQL.
- [x] Token exchange e sessione OAuth2 verificati dopo il riavvio.
- [x] Errore `unauthorized_client` risolto.

### Da verificare

- [ ] Aggiornare il client secret nel file di import del realm per mantenere coerente l'IaC.
- [ ] Analizzare i restart di Keycloak, PostgreSQL, Redis e WebProxy.
- [ ] Ruotare i secret eventualmente esposti durante il debugging.
- [ ] Separare i secret dal repository Git tramite gestione sicura delle credenziali.

### Note operative

- Non modificare OpenEMS durante la risoluzione dei problemi di autenticazione.
- Non cancellare il database PostgreSQL o il PVC `keycloak-db-data`.
- Non ricreare il realm finché non è chiaro il comportamento dell'importazione.
- Prima di applicare modifiche, confrontare sempre manifest Kustomize e risorse live.
- Per ogni modifica, annotare data, file modificato, comando eseguito e risultato.

### Registro modifiche

| Data | Componente | Modifica o verifica | Risultato |
|---|---|---|---|
| 2026-08-13 | OpenEMS Edge | Configurazione PVC e initContainer | Funzionante |
| 2026-08-13 | Keycloak | Verifica realm e utente `testuser` | Utente autenticato |
| 2026-08-13 | OAuth2 Proxy | Analisi errore callback | `unauthorized_client` identificato |
| 2026-08-13 | Keycloak/OAuth2 Proxy | Allineamento client secret | Da verificare dopo restart |
| 2026-08-13 | PostgreSQL | Verifica Deployment e PVC | PVC presente ma non montato |

## Regole di sicurezza

- Non committare password, client secret o cookie secret in chiaro.
- Non condividere output completi di Secret Kubernetes.
- Usare secret casuali e sufficientemente lunghi.
- Ruotare i secret dopo un'esposizione accidentale.
- Limitare gli aggiornamenti al componente interessato.
- Conservare backup del database prima di modifiche alla persistenza.
