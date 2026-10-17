# Attacchi dimostrativi: uno per misconfigurazione

Tre attacchi, uno per ciascuna delle tre misconfigurazioni del capitolo
sicurezza. Ognuno **sfrutta** la misconfig fino all'impatto e mostra la
contromisura che lo neutralizza (`DEFENSE=1`), con pulizia/ripristino automatico.

## Test ≠ attacco

C'è una distinzione netta e voluta tra i due tipi di script:

- **Test (`01`–`03`)** — *verificano* la presenza della misconfigurazione, in
  sola lettura o con esperimenti innocui. Rispondono a «la misconfig c'è?».
- **Attacco (`04`–`06`)** — *sfruttano* la misconfigurazione sul cluster vivo,
  producendo un impatto reale (e reversibile). Rispondono a «cosa può farci un
  attaccante?».

| Misconfig | Test (verifica) | Attacco (sfruttamento) |
|---|---|---|
| 1 · Token SA automontato (riga 4) | `01-automount-sa-token.sh` | `04-attacco-token-lateral-movement.sh` |
| 2 · Workload sul control plane (riga 8) | `02-control-plane-scheduling.sh` | `05-attacco-control-plane-dos.sh` |
| 3 · Override del Secret in Helm (riga 19) | `03-helm-secret-override.sh` | `06-attacco-helm-secret-injection.sh` |

## I tre attacchi in breve

1. **A1 — Furto del token e movimento laterale**
   ([README](04-attacco-token-lateral-movement.md)).
   Dal pod esposto ruba il token del ServiceAccount (MITRE T1528), raggiunge
   l'API server e, sfruttando un permesso plausibile (`create pods`, T1610), crea
   un pod che monta il filesystem del nodo. Poiché i pod girano anche sul control
   plane (misconfig 2), legge le CA del cluster: **dal pod al controllo del
   cluster**.

2. **A2 — DoS del control plane per co-locazione**
   ([README](05-attacco-control-plane-dos.md)).
   Schedula un pod ostile **sul nodo di controllo** (nessun taint lo vieta) e vi
   fa girare un carico che compete con etcd/apiserver, **degradando il control
   plane**. Misura la latenza dell'API prima e durante.

3. **A3 — Iniezione di credenziali via Helm**
   ([README](06-attacco-helm-secret-injection.md)).
   Crea un Secret proprio e con un solo `helm upgrade --set
   global.existingSecret=...` fa ripartire **tutto lo stack di autenticazione**
   con credenziali scelte dall'attaccante. Ripristino con `helm rollback`.

## Sicurezza e reversibilità

Tutti gli attacchi sono pensati per il **laboratorio didattico** della tesi, sul
cluster di prova (Minikube), a scopo educativo e difensivo:

- impatto **limitato nel tempo** e **reversibile** (`activeDeadlineSeconds`,
  `trap EXIT`, `helm rollback`);
- **nessuna esfiltrazione** di dati e **nessuna stampa di credenziali reali** (la
  prova d'impatto è un `ls` o un conteggio; i valori iniettati sono marcatori
  dell'attaccante);
- da eseguire **solo sul proprio cluster**, mai su sistemi reali.

Le contromisure complete sono in [`README.md`](README.md); ogni README d'attacco
riporta anche le fonti citabili in bibliografia (MITRE ATT&CK, NSA/CISA,
Microsoft Threat Matrix, documentazione Kubernetes/Helm).
