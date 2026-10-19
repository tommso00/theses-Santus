# Fix delle misconfigurazioni — parte a livello di cluster

Questo branch `misconfig-fixed` corregge le tre misconfigurazioni del capitolo
sicurezza. **I fix si dividono in due gruppi.**

## 1. Fix nel chart (già applicati in questo branch)

Rigenerati a ogni `helm upgrade`, senza passi manuali:

| Misconfig | Fix nel chart | Dove |
|---|---|---|
| **1** · Token SA automontato | ServiceAccount dedicati per componente (`smartgrid-openems/pmu/timedata/auth`), tutti con `automountServiceAccountToken: false`; ogni pod imposta `serviceAccountName` e non monta più il token | `templates/serviceaccounts.yaml`, `spec` di ogni workload |
| **3** · Override del Secret in Helm | `global.existingSecret` vincolato con `enum` nello schema: `--set global.existingSecret=<altro>` è rifiutato | `values.schema.json` |
| **2** · (parte) confinamento risorse | `LimitRange` sempre attiva; `ResourceQuota` opzionale (`resourceQuota.enabled=true`) da dimensionare | `templates/resource-governance.yaml`, `values.yaml` |

Verifica rapida (richiede `helm`):

```bash
# misconfig 1: nessun token montato, SA dedicato
helm template smartgrid charts/smartgrid | grep -E 'serviceAccountName|automountServiceAccountToken' | sort | uniq -c
# misconfig 3: l'override viene rifiutato dallo schema
helm template smartgrid charts/smartgrid --set global.existingSecret=attacker-controlled-secret   # atteso: errore di validazione
```

## 2. Fix a livello di cluster (da applicare a mano)

La separazione workload ↔ control plane (misconfig 2) e alcune difese in
profondità **non possono stare nel chart**: la `nodeAffinity` "non sul control
plane" renderebbe tutti i pod non schedulabili su un Minikube a nodo singolo, e
taint/admission/Pod Security sono proprietà del cluster, non del rilascio Helm.
Si applicano una volta sul cluster.

### a) Taint sul nodo del control plane (misconfig 2)

Respinge i pod applicativi dal nodo di controllo. Su Minikube serve più di un
nodo, altrimenti non resta dove schedulare:

```bash
minikube start --nodes 2                 # un worker oltre al control plane
CP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "$CP" node-role.kubernetes.io/control-plane=:NoSchedule
```

Nei cluster gestiti (EKS/GKE/AKS) il control plane è già fuori dalla portata dei
workload: questo passo non serve.

### b) ValidatingAdmissionPolicy (misconfig 2)

Rifiuta i pod che tollerano o selezionano il control plane, così il taint non si
aggira con una toleration:

```bash
kubectl apply -f security-fixes/validatingadmissionpolicy-no-controlplane.yaml
```

### c) Pod Security Admission "restricted" (misconfig 1 e 2)

Vieta `hostPath`, container privilegiati e `runAsRoot`: blocca il pod che
l'attacco A1 usa per montare il filesystem del nodo.

```bash
kubectl label namespace smartgrid \
  pod-security.kubernetes.io/enforce=restricted --overwrite
```

> Nota: lo stack attuale non imposta i `securityContext`, quindi `restricted`
> potrebbe rifiutare anche pod legittimi finché non si aggiungono
> `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`
> e `seccompProfile`. Provare prima in `warn`/`audit`:
> `pod-security.kubernetes.io/warn=restricted`.

### d) NetworkPolicy di egress (misconfig 1, difesa in profondità)

Taglia la rotta pod → API server, così un token rubato è inutilizzabile
dall'interno del pod. Nel branch il token non è più montato, quindi è una difesa
aggiuntiva. **Punto di partenza, da completare e testare** (vedi avvertenza nel
file):

```bash
kubectl apply -f security-fixes/networkpolicy-egress-starter.yaml
```

## Come usare le due versioni per test e attacchi

- Branch `helm-multi-edge` (vulnerabile): gli attacchi `security-demos/04–06`
  riescono.
- Branch `misconfig-fixed` + i fix cluster-level qui sopra: gli stessi attacchi
  falliscono nello stesso punto in cui la modalità `DEFENSE=1` di ciascuno
  mostra la contromisura. In particolare: A1 non trova token da rubare, A2 non
  può schedulare sul control plane (con taint + policy), A3 non può sovrascrivere
  il nome del Secret.
