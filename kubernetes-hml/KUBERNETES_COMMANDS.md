# Comandos do ambiente HML

Execute na VM com o usuário que recebeu `~/.kube/config`:

```bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.metadata.creationTimestamp
kubectl get gatewayclass
kubectl get gateway,httproute,grpcroute -A
kubectl -n kubernetes-dashboard get deployment,service,pod
kubectl -n envoy-gateway-system get deployment,service,pod
kubectl -n cattle-system get deployment,pod
```

Verificar componentes e acesso:

```bash
sudo bash diagnose.sh cluster.env
sudo env K8S_CONFIG_FILE="$PWD/cluster.env" bash scripts/90-verify.sh
sudo env K8S_CONFIG_FILE="$PWD/cluster.env" bash scripts/80-register-rancher.sh --check
```

Logs de uma aplicação:

```bash
kubectl -n NAMESPACE logs deployment/APLICACAO --tail=100
kubectl -n NAMESPACE describe pod POD
```

O kubeconfig local é administrativo. Guarde-o com modo `0600`; para usuários da equipe, crie permissões próprias no Rancher. O Headlamp sem senha usa uma identidade administrativa compartilhada, conforme descrito no README.
