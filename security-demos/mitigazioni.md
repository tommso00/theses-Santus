# Mitigazioni

### 1. Automounted high-privilege ServiceAccount tokens

**Principio:** identità minima per ogni componente e nessun token montato se non serve. Nessun pod del progetto usa l'API Kubernetes, quindi il token non dovrebbe esistere affatto nei pod.

1. **Disattivare il mount del token.** A livello di pod, in ogni Deployment:
   ```yaml
   spec:
     template:
       spec:
         automountServiceAccountToken: false
   ```
   In alternativa, impostarlo sul ServiceAccount così da non ripeterlo. È la mitigazione principale e a costo zero.
2. **Un ServiceAccount dedicato per componente**, invece del `default` condiviso, così da poter dare permessi minimi e distinguere i chiamanti nei log di audit. Il chart li può generare (uno per Edge, bridge, Backend, auth).
3. **Bloccare l'egress verso l'API server** con una NetworkPolicy: oggi `networkpolicy-default-deny.yaml` filtra solo l'ingress. Aggiungere un default-deny in uscita e permettere solo il DNS e le destinazioni necessarie taglia la catena "pod compromesso → API server".
4. **Pod Security Admission** a livello `restricted` sul namespace, come difesa in profondità.

**Verifica:** rieseguire `01-automount-sa-token.sh`. Atteso dopo la fix: la cartella `/var/run/secrets/.../` non esiste e la chiamata all'API server dal pod fallisce in timeout (egress bloccato) invece di tornare 403.

### 2. Workloads scheduled on control-plane nodes

**Principio:** il control plane non deve ospitare workload applicativi.

1. **Taint sul nodo control-plane** e nodi worker dedicati:
   ```bash
   kubectl taint nodes <cp-node> node-role.kubernetes.io/control-plane=:NoSchedule
   ```
   In un cluster gestito (EKS/GKE/AKS) questo è già garantito: il control plane è fuori dalla portata dell'utente. Da scrivere nella tesi come differenza tra l'ambiente di prova (Minikube monodo) e un ambiente di produzione.
2. **Minikube a più nodi** per le prove che richiedono la separazione: `minikube start --nodes 2` e taint sul primo nodo.
3. **`requests`/`limits` realistici** (già presenti) più un `PriorityClass` per i componenti di sistema, così i workload non sottraggono risorse al control plane sotto carico.
4. **nodeSelector/affinity** sui Deployment per fissarli esplicitamente sui nodi worker, a complemento del taint.

**Verifica:** `02-control-plane-scheduling.sh` su un cluster multinodo con taint: i pod dello stack devono comparire solo sul nodo worker.

### 3. Helm allows secret name override

**Principio:** il nome del Secret delle credenziali non deve essere un parametro arbitrario che un singolo `--set` può dirottare.

1. **Fissare il nome del Secret** nel chart (`_helpers.tpl`) invece di leggerlo da `global.existingSecret`, oppure legarlo al nome della release: `{{ .Release.Name }}-auth`. Toglie del tutto la possibilità di override.
2. Se l'override deve restare configurabile, **validarlo** in `values.schema.json` con un `pattern`/`enum` che accetti solo nomi attesi, e **non** solo `minLength: 1`.
3. **Secret separati per componente** invece di un unico `auth-secrets`: anche puntando il chart altrove, l'attaccante dovrebbe sostituirne molti, e si riduce il raggio d'azione (collegamento con "Excessive RBAC allowing Secret reads").
4. **Controllo RBAC a monte:** limitare chi può fare `helm upgrade` / `kubectl apply` nel namespace e chi può creare Secret, perché l'override vale solo se l'attaccante può anche creare il Secret malevolo. In GitOps, protezione del branch e review obbligatoria sui values.
5. **Verifica di integrità:** riferirsi ai Secret per `secretKeyRef` con nome fisso e, dove possibile, usare `immutable: true` sui Secret (vedi anche "Mutable secrets").

**Verifica:** rieseguire `03-helm-secret-override.sh`. Atteso dopo la fix: `--set global.existingSecret=...` non cambia i manifest (nome fisso) oppure lo schema rifiuta il valore con un errore di validazione.
