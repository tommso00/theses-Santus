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

```bash
cd security-demos
./01-automount-sa-token.sh smartgrid            # sola osservazione
LAB=1 ./01-automount-sa-token.sh smartgrid      # + esperimento di escalation (pulito a fine run)
./02-control-plane-scheduling.sh smartgrid
METRICS=1 ./02-control-plane-scheduling.sh      # + misura del carico
./03-helm-secret-override.sh                    # cerca da solo charts/smartgrid
```

