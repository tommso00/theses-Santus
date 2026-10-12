# Demo di sicurezza: tre misconfigurazioni e le relative mitigazioni

Tre misconfigurazioni del foglio STRIDE "Misconfigs" presenti nel chart `charts/smartgrid`, ciascuna con uno script che la dimostra e con le mitigazioni.

| # | Misconfig | Script |
|---|---|---|
| 1 | Automounted high-privilege ServiceAccount tokens | `01-automount-sa-token.sh` |
| 2 | Workloads scheduled on control-plane nodes | `02-control-plane-scheduling.sh` |
| 3 | Helm allows secret name override | `03-helm-secret-override.sh` |

## Come eseguirli

Servono `kubectl` puntato al cluster Minikube (script 1 e 2) e `helm` (script 3).
Lo script 3 **non** richiede un cluster: usa solo `helm template`.

Per la misura del carico dello script 2 (`METRICS=1`) serve anche il metrics-server, che su Minikube si abilita una volta sola con `minikube addons enable metrics-server`.
Senza di esso la sezione 4 dello script fallisce con "Metrics API not available".

Prima del primo avvio bisogna rendere eseguibili gli script (passo una tantum), perché potrebbero non arrivare con il bit di esecuzione (ad esempio dopo il download di uno zip o la copia da un altro sistema).

```bash
cd security-demos
chmod +x *.sh                                   # una tantum: rende eseguibili gli script
./01-automount-sa-token.sh smartgrid            # sola osservazione
LAB=1 ./01-automount-sa-token.sh smartgrid      # + esperimento di escalation (pulito a fine run)
./02-control-plane-scheduling.sh smartgrid
minikube addons enable metrics-server           # una tantum: necessario per METRICS=1
METRICS=1 ./02-control-plane-scheduling.sh      # + misura del carico
./03-helm-secret-override.sh                    # cerca da solo charts/smartgrid
```
