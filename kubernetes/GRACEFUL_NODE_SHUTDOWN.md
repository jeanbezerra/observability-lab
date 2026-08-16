# Graceful Node Shutdown no Kubernetes

Em clusters Kubernetes executados diretamente sobre Linux com `systemd`, o processo de reboot pode demorar excessivamente quando o kubelet não possui uma janela configurada para encerrar os Pods de forma graciosa.

Um sintoma comum é o sistema permanecer aguardando por muito tempo durante o shutdown em mensagens semelhantes a:

```text
Job cri-containerd-<container-id>.scope/stop running
```

No ambiente deste laboratório, o problema foi resolvido habilitando o **Graceful Node Shutdown** no kubelet.

## Configuração

Edite:

```bash
sudo vim /var/lib/kubelet/config.yaml
```

Localize:

```yaml
shutdownGracePeriod: 0s
shutdownGracePeriodCriticalPods: 0s
```

Altere para:

```yaml
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 15s
```

A configuração reserva até 30 segundos para o processo de shutdown do node, sendo os últimos 15 segundos destinados aos Pods críticos, como os componentes do control plane.

Reinicie o kubelet:

```bash
sudo systemctl restart kubelet
```

Valide:

```bash
grep -E \
'^(shutdownGracePeriod|shutdownGracePeriodCriticalPods)' \
/var/lib/kubelet/config.yaml
```

Saída esperada:

```text
shutdownGracePeriod: 30s
shutdownGracePeriodCriticalPods: 15s
```

Verifique também o estado do node:

```bash
kubectl get nodes
```

O node deve permanecer:

```text
STATUS
Ready
```

## Teste de reboot

Antes do teste:

```bash
kubectl get pods -A
```

Confirme que os principais componentes estão `Running`.

Execute:

```bash
sudo reboot
```

Durante o shutdown, o kubelet passa a coordenar o encerramento dos Pods antes que `containerd` e `systemd` finalizem os respectivos containers e scopes.

Após o servidor retornar:

```bash
kubectl get nodes
kubectl get pods -A
```

O resultado esperado é:

```text
Node: Ready
Flannel: Running
CoreDNS: Running
etcd: Running
kube-apiserver: Running
kube-controller-manager: Running
kube-scheduler: Running
Headlamp: Running
```

Para verificar o boot atual:

```bash
journalctl -u kubelet -b --no-pager | grep -Ei \
'shutdown|grace|error|failed'
```

E para analisar o shutdown anterior:

```bash
journalctl -b -1 --no-pager | grep -Ei \
'cri-containerd|shutdown|stop running'
```

## Resultado esperado

Antes:

```text
reboot
  ↓
systemd inicia shutdown
  ↓
containers ainda estão ativos
  ↓
containerd aguarda encerramento
  ↓
cri-containerd-*.scope pode permanecer bloqueado
```

Depois:

```text
reboot
  ↓
kubelet coordena o Graceful Node Shutdown
  ↓
Pods são encerrados
  ↓
Pods críticos recebem janela reservada
  ↓
containerd finaliza os containers
  ↓
systemd conclui o shutdown
```

> Esta configuração deve ser incorporada à automação de provisionamento do cluster para evitar drift após reinstalações, upgrades ou recriação do node.
