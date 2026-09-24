# Encerramento do nó Kubernetes no WSL 2

O kubelet desta pasta é criado com:

```yaml
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 15s
```

Esses valores permitem encerramento gracioso quando o systemd recebe um desligamento normal. Ainda assim, `wsl.exe --terminate` e `wsl.exe --shutdown` podem finalizar a VM mais rapidamente do que um servidor Linux físico. O cluster é de desenvolvimento e nó único; não trate esse mecanismo como garantia de disponibilidade ou durabilidade de produção.

## Antes de encerrar o WSL

Para workloads com estado, finalize o trabalho e confira os Pods:

```bash
kubectl get pods -A
kubectl get events -A --sort-by='.metadata.creationTimestamp'
```

Quando quiser dar ao systemd a oportunidade de parar os serviços primeiro:

```bash
sudo systemctl stop k8s-gateway-local.service k8s-headlamp-local.service
sudo systemctl stop kubelet.service
sudo systemctl stop containerd.service
```

Depois, no **CMD do Windows**:

```bat
wsl.exe --terminate Ubuntu-26.04
```

Não use remoção forçada de Pods como rotina. Prefira:

```bash
kubectl delete pod POD -n NAMESPACE --wait=true --timeout=2m
```

## Depois de abrir novamente o Ubuntu

```bash
systemctl is-active k8s-wsl-node-ip containerd kubelet k8s-headlamp-local k8s-gateway-local
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl get pods -A
```

O serviço `k8s-wsl-node-ip` recria o endereço estável antes do kubelet. Se o nó não voltar:

```bash
ip address show dev lo
sudo journalctl -b -u k8s-wsl-node-ip -u containerd -u kubelet --no-pager
sudo crictl ps -a
```

O endereço definido por `NODE_IP` deve aparecer como `/32` na interface `lo`.
