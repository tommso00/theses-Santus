# Demo di sicurezza: misconfigurazioni, attacchi e mitigazioni

Documento unico della cartella `security-demos` (sostituisce `Istruzioni.md`, `attacchi.md`, `mitigazioni.md`, `modello-attaccante-04-06.md` e `04-ingresso-vulnerabilita.md`). Raccoglie: le tre misconfigurazioni studiate, come eseguire gli script, il modello di attaccante, la descrizione dei tre attacchi e le mitigazioni.

Tutto è pensato per il **laboratorio didattico** della tesi, su un cluster di prova **Minikube**, a scopo **educativo e difensivo**. Da eseguire **solo sul proprio cluster**.

---

## 1. Le tre misconfigurazioni

Tre misconfigurazioni del foglio STRIDE "Misconfigs" presenti nel chart `charts/smartgrid`. Per ciascuna c'è uno script di **test** (verifica se la misconfig c'è) e uno di **attacco** (mostra cosa può farne un attaccante).

| # | Misconfig (riga STRIDE) | Test | Attacco |
|---|---|---|---|
| 1 | Token SA automontato ad alto privilegio (riga 4) | `01-automount-sa-token.sh` | `04-attacco-token-lateral-movement.sh` |
| 2 | Workload schedulati sul nodo control-plane (riga 8) | `02-control-plane-scheduling.sh` | `05-attacco-control-plane-dos.sh` |
| 3 | Helm permette l'override del nome del Secret (riga 19) | `03-helm-secret-override.sh` | `06-attacco-helm-secret-injection.sh` |

**Test ≠ attacco.** I test (`01`–`03`) *verificano* la presenza della misconfig, in sola lettura o con esperimenti innocui («la misconfig c'è?»). Gli attacchi (`04`–`06`) la *sfruttano* fino all'impatto, in modo reversibile («cosa può farci un attaccante?»).

> **Nota importante.** Il chart `charts/smartgrid` è già la versione **corretta** per tutte e tre le misconfig (ServiceAccount dedicati con token non montato; `global.existingSecret` vincolato da `enum` nello schema; default-deny in ingresso). Contro il deploy reale, quindi, gli attacchi si **fermano presto**: è la prova che le difese reggono. Per osservare l'impatto completo in laboratorio, gli script offrono flag che modellano una variante *vulnerabile* del deploy (vedi §3), chiaramente etichettati come preparazione dell'ambiente e **non** come azioni dell'attaccante.

---

## 2. Come eseguirli

Servono `kubectl` puntato al cluster Minikube e, per lo script 3 e 6, `helm`. Lo script 3 non richiede un cluster (usa solo `helm template`).

Rendere eseguibili gli script una tantum (il bit di esecuzione può mancare dopo un download/copia):

```bash
cd security-demos
chmod +x *.sh
```

**Test (01–03):**

```bash
./01-automount-sa-token.sh smartgrid            # sola osservazione
LAB=1 ./01-automount-sa-token.sh smartgrid      # + esperimento di escalation (pulito a fine run)
./02-control-plane-scheduling.sh smartgrid
minikube addons enable metrics-server           # una tantum: necessario per METRICS=1
METRICS=1 ./02-control-plane-scheduling.sh      # + misura del carico
./03-helm-secret-override.sh                    # cerca da solo charts/smartgrid
```

**Attacchi (04–06):**

```bash
./04-attacco-token-lateral-movement.sh smartgrid          # ingresso + catena (si ferma dove la config lo impone)
SIMULA_RBAC_ECCESSIVO=1 ./04-attacco-token-lateral-movement.sh   # modella un cluster con RBAC eccessivo

./05-attacco-control-plane-dos.sh smartgrid               # foothold co-locato -> prova di accesso al control plane

./06-attacco-helm-secret-injection.sh                     # richiede la release Helm viva
SIMULA_SCHEMA_DEBOLE=1 ./06-attacco-helm-secret-injection.sh     # modella un chart con schema non vincolato
```

Gli attacchi sono reversibili: ogni script rimuove le proprie risorse di laboratorio a fine run (`trap EXIT`), il 06 ripristina con `helm rollback`. Nessuna esfiltrazione, nessuna stampa di credenziali reali (la prova d'impatto è un `ls` o un conteggio; i valori iniettati sono marcatori evidenti).

---

## 3. Modello di attaccante

Gli attacchi 04 e 05 adottano un modello esplicito e volutamente ristretto, per non sopravvalutare l'attaccante:

- **Outsider** — nessuna credenziale Kubernetes, nessun accesso al cluster; parte solo dalla rete e dalle superfici esposte.
- **Zero-knowledge** — non sa se le misconfig ci sono; le **scopre** sondando e osservando le risposte (principio di Kerckhoffs: niente sicurezza basata sull'ignoranza dell'attaccante).
- **Privilegi minimi** — a ogni passo usa solo ciò che ha **verificato** di avere; non si auto-concede ruoli, non usa credenziali admin.

L'attacco **06 è l'eccezione dichiarata**: il deploy del progetto è `helm upgrade` **locale** (non GitOps), quindi sostituire la fonte delle credenziali richiede il permesso di fare l'upgrade. È modellato come **insider del deploy o credenziali di deploy rubate**.

**Principio trasversale:** *ogni passo è una sonda che può fermare la catena*. L'attaccante arriva solo fin dove la configurazione reale glielo consente; quando un anello manca, lo script dichiara "catena fermata al passo N" e quale difesa ha retto. È un esito **desiderato**, non un fallimento della demo.

Terminologia per la tesi: *insider/outsider*, *locale/remoto*, *Dolev–Yao* ristretto al perimetro (osservare/modificare/iniettare), *defence in depth*.

---

## 4. I tre attacchi in dettaglio

### A1 — Dall'ingresso al token, poi movimento laterale (`04`)

**Ingresso (stage 0).** L'outsider ottiene il foothold sfruttando una vulnerabilità applicativa sul servizio esposto — tecnica **MITRE ATT&CK T1190** ("Exploit Public-Facing Application"). In laboratorio lo stage è *rappresentato* con `kubectl exec` nel pod esposto: non si distribuisce un exploit funzionante (sarebbe *offensive tooling*, fragile e fuori tema); l'ingresso è un **passo nominato e documentato**.

Classi di vulnerabilità rilevanti per questo stack:

| Classe | CWE | Dove è plausibile | Esito |
|---|---|---|---|
| JNDI injection da libreria di log | CWE-917 | Componenti JVM (OpenEMS, Keycloak) | RCE nel container |
| OS command injection | CWE-78 | Endpoint che invocano comandi | RCE nel container |
| Deserializzazione non sicura | CWE-502 | Servizi Java/.NET | RCE nel container |
| Server-Side Request Forgery | CWE-918 | Componenti che fanno richieste lato server | accesso a servizi interni |
| Bypass di autenticazione | CWE-287 | Keycloak / OAuth2 Proxy mal configurati | accesso non autorizzato |

**CVE di riferimento citabile: Log4Shell (CVE-2021-44228)** — RCE in Apache Log4j 2 (≤ 2.14.1), CVSS 10.0. Quando Log4j registra una stringa controllata dall'attaccante, interpreta un *lookup* JNDI (`${jndi:ldap://…}`) e carica/esegue una classe remota, senza autenticazione. È l'archetipo dello sfruttamento di un'app esposta su JVM (OpenEMS, Keycloak). *Passi concettuali* (per la tesi, senza payload né automazione): (1) l'attaccante individua un servizio esposto con Log4j vulnerabile; (2) predispone un endpoint remoto; (3) invia una richiesta in cui un campo loggato contiene il lookup JNDI; (4) Log4j risolve il lookup e l'app esegue il codice dell'attaccante nel pod; (5) esito = foothold. Lo script 04 rappresenta direttamente l'esito del passo 5.

**La catena (col foothold ottenuto):**
1. **Verifica** se il token del ServiceAccount è montato nel pod (misconfig 1, `T1528`). Se no → *catena fermata al passo 1*.
2. **Sonda** se dal pod si raggiunge l'API server (egress non filtrato). Se no → *catena fermata al passo 2*.
3. **Enumera** i permessi reali dell'identità (`auth can-i --list`) e usa solo quelli — nessun over-grant auto-concesso.
4. Solo se il RBAC lo consente davvero (condizione "Excessive RBAC"), crea un pod con `hostPath` (`T1610`) e, se finisce sul control plane (misconfig 2), legge CA/kubeconfig admin (prova con `ls`). Altrimenti → *catena fermata al passo 4*.

*Modello:* outsider con 1 foothold applicativo; permessi = solo il processo nel pod; sa solo ciò che verifica. Proprietà colpita: confidenzialità → controllo del cluster.

### A2 — Dal foothold co-locato al control plane (`05`)

Il pod applicativo esposto gira **sul nodo di controllo** perché nessuna policy lo impedisce (misconfig 2: niente taint). Dal foothold, l'attaccante **tenta di raggiungere il control plane**.

**Punto scientifico (da scrivere in tesi):** la co-locazione **da sola non basta** — un pod normale resta isolato (namespace, niente host-fs, niente host-loopback). Per "mettere mano" nel control plane servono **due** policy mancanti *insieme*:

1. **nessun taint** sul nodo di controllo → il pod applicativo ci finisce;
2. **nessuna Pod Security Admission `restricted`** → al pod è permesso un mount pericoloso (`hostPath`) / `hostNetwork` / privilegi.

Con entrambe mancanti, il foothold legge CA e kubeconfig dal filesystem del nodo (prova con `ls`). Con **una qualsiasi** presente, la catena si ferma. **Il focus è la mancanza di policy**, non il privilegio dell'attaccante.

*Modello:* outsider con foothold; permessi = solo ciò che il pod espone. Proprietà colpita: confidenzialità → controllo (se le policy mancano), altrimenti contesa di risorse.

### A3 — Iniezione di credenziali via Helm, attacco da insider (`06`)

Chi può fare `helm upgrade` (operatore infedele o credenziali di deploy rubate) crea un Secret proprio con credenziali note e con un solo `--set global.existingSecret=<evil>` fa ripartire **tutto lo stack di autenticazione** sulle sue credenziali (`T1565` "Data Manipulation" / `T1078` "Valid Accounts"). Riesce **solo** se lo schema non vincola il nome; con `enum`/`pattern` (come nel chart corretto) l'override è rifiutato e la catena si ferma. Ripristino con `helm rollback`.

*Modello:* insider del deploy / credenziali rubate; privilegi minimi (`create secret` + `helm upgrade`), zero-knowledge sui *valori* (conosce solo i nomi delle chiavi). Impatto: col client secret forgia sessioni/token; col token InfluxDB legge o **falsifica le misure PMU** (integrità dei dati).

---

## 5. Mitigazioni

### 5.1 Token SA automontato (misconfig 1)

**Principio:** identità minima per ogni componente e nessun token montato se non serve.

1. **`automountServiceAccountToken: false`** su ogni pod (o sul ServiceAccount). Mitigazione principale e a costo zero.
2. **Un ServiceAccount dedicato per componente** invece del `default` condiviso: permessi minimi e chiamanti distinguibili nei log di audit.
3. **NetworkPolicy di egress**: oggi `networkpolicy-default-deny.yaml` filtra solo l'ingress; aggiungere un default-deny in uscita (permettendo solo DNS e destinazioni necessarie) taglia la catena "pod compromesso → API server".
4. **Pod Security Admission `restricted`** sul namespace, come difesa in profondità.

*Verifica:* `01-automount-sa-token.sh` dopo la fix: la cartella `/var/run/secrets/.../` non esiste e la chiamata all'API dal pod va in timeout. L'attacco `04` sul chart corretto si ferma al passo 1 o 2. Le contromisure che spezzano ciascun anello sono quelle elencate qui.

### 5.2 Workload sul control plane (misconfig 2)

**Principio:** il control plane non deve ospitare workload applicativi, e un eventuale pod co-locato non deve poter uscire dal proprio isolamento.

1. **Taint sul nodo control-plane** e nodi worker dedicati: `kubectl taint nodes <cp-node> node-role.kubernetes.io/control-plane=:NoSchedule`. In un cluster gestito (EKS/GKE/AKS) è già garantito — da scrivere in tesi come differenza tra Minikube monodo e produzione.
2. **Minikube multinodo** per provare la separazione: `minikube start --nodes 2` + taint sul primo nodo.
3. **`requests`/`limits`** realistici (già presenti) + una **`PriorityClass`** per i componenti di sistema.
4. **nodeSelector/affinity** sui Deployment per fissarli sui worker, a complemento del taint.
5. **Pod Security Admission `restricted`** — anello indispensabile: anche se un pod finisse sul control plane, senza `hostPath`/`hostNetwork`/privilegi non può leggere il nodo. L'attacco `05` mostra che la co-locazione **da sola** non basta: taint e PSA vanno insieme.

*Verifica:* `02-control-plane-scheduling.sh` su cluster multinodo con taint: i pod dello stack compaiono solo sul worker. Con taint + PSA, il foothold co-locato dell'attacco `05` non raggiunge il materiale del control plane.

### 5.3 Override del nome del Secret in Helm (misconfig 3)

**Principio:** il nome del Secret non deve essere un parametro arbitrario sovrascrivibile con un singolo `--set`.

1. **Fissare il nome** nel chart (`_helpers.tpl`) o legarlo alla release (`{{ .Release.Name }}-auth`): toglie del tutto l'override.
2. Se deve restare configurabile, **validarlo** in `values.schema.json` con `pattern`/`enum` (non solo `minLength: 1`). *(Già presente nel chart: `enum: ["auth-secrets"]`.)*
3. **Secret separati per componente** invece di un unico `auth-secrets`: riduce il raggio d'azione.
4. **Controllo RBAC a monte:** limitare chi può fare `helm upgrade`/`kubectl apply` e chi può creare Secret. Il deploy è `helm upgrade` locale, quindi l'attaccante del `06` è un insider del deploy o chi ne ha rubato le credenziali: restringere chi le detiene è la mitigazione a monte. In GitOps: protezione del branch e review obbligatoria sui values.
5. **Integrità:** `secretKeyRef` con nome fisso e, dove possibile, `immutable: true` sui Secret.

*Verifica:* `03-helm-secret-override.sh` dopo la fix: `--set global.existingSecret=...` non cambia i manifest, oppure lo schema rifiuta il valore. L'attacco `06` sul chart corretto si ferma al passo 3 ("override rifiutato dallo schema").

---

## 6. Riferimenti

- MITRE ATT&CK: T1190, T1528, T1610, T1565, T1078, T1499 — https://attack.mitre.org/
- MITRE CWE: CWE-917, CWE-502, CWE-78, CWE-918, CWE-287 — https://cwe.mitre.org/
- NVD — CVE-2021-44228 (Log4Shell): https://nvd.nist.gov/vuln/detail/CVE-2021-44228
- Apache Log4j Security: https://logging.apache.org/log4j/2.x/security.html
- CISA — Apache Log4j Guidance: https://www.cisa.gov/news-events/news/apache-log4j-vulnerability-guidance
- NSA/CISA — Kubernetes Hardening Guidance 1.2 (2022)
- Microsoft — Threat Matrix for Kubernetes
- Documentazione Kubernetes (Pod Security Admission, taints & tolerations, ServiceAccount) e Helm (values schema)
