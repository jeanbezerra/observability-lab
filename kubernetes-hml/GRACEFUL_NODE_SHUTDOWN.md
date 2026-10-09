# Desligamento da VM HML

O kubelet usa `shutdownGracePeriod: 30s` e `shutdownGracePeriodCriticalPods: 15s`. Para permitir o encerramento gracioso dos Pods, desligue o Ubuntu normalmente:

```bash
kubectl get pods -A
sudo shutdown -h now
```

Para reiniciar, use `sudo reboot`. Evite desligamento forçado pelo hipervisor: o nó único interrompe aplicações durante o desligamento e não oferece alta disponibilidade. Faça backup dos dados persistentes e do etcd antes de manutenção.

Depois de iniciar a VM:

```bash
systemctl is-active k8s-hml-node-network containerd kubelet
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl get pods -A
ip -4 address show scope global
sudo bash diagnose.sh cluster.env
```

O IP informado em `NODE_IP` precisa continuar presente na interface da VM. O serviço de rede valida esse IP, carrega módulos e configura sysctls; não cria endereços nem altera DHCP/netplan. Se houver falha:

```bash
sudo journalctl -b -u k8s-hml-node-network -u containerd -u kubelet --no-pager
sudo crictl ps -a
```
