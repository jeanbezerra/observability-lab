# Comandos comuns de administração Kubernetes

Este guia considera o cluster criado por este diretório, com Kubernetes `v1.36`, kubeconfig administrativo em `/etc/kubernetes/admin.conf` e Dashboard Headlamp no namespace `kubernetes-dashboard`.

> Substitua os valores em maiúsculas (`NAMESPACE`, `POD`, `DEPLOYMENT`, `CONTAINER`) antes de executar. Comandos de exclusão e `--force` podem interromper serviços ou causar perda de dados.

## Preparar a sessão administrativa

Como `root` no nó do cluster:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl cluster-info
kubectl get nodes
```

Como o usuário configurado em `ADMIN_USER`, o instalador já fornece `~/.kube/config`:

```bash
kubectl config current-context
kubectl auth whoami
```

Atalhos opcionais para a sessão atual:

```bash
alias k=kubectl
export NS=default
export APP=minha-aplicacao
```

Autocompletar no Bash:

```bash
source <(kubectl completion bash)
complete -o default -F __start_kubectl k
```

## Cluster, contextos e APIs

```bash
# Versões do cliente e servidor
kubectl version

# Informações dos endpoints do cluster
kubectl cluster-info

# Contexto atual e contextos disponíveis
kubectl config current-context
kubectl config get-contexts

# Trocar contexto
kubectl config use-context NOME_DO_CONTEXTO

# Definir namespace padrão no contexto atual
kubectl config set-context --current --namespace=NAMESPACE

# Listar namespaces, nós e recursos suportados pela API
kubectl get namespaces
kubectl get nodes -o wide
kubectl api-resources
kubectl api-versions

# Explicar campos de um recurso
kubectl explain deployment
kubectl explain deployment.spec.template.spec.containers
```

`kubectl get all` mostra somente um conjunto comum de recursos; não inclui Secrets, ConfigMaps, PVCs, NetworkPolicies e vários outros tipos.

## Visão geral e acompanhamento

```bash
# Recursos comuns de um namespace
kubectl get all -n "$NS"

# Pods em todos os namespaces, com nó e IP
kubectl get pods -A -o wide

# Atualizar a listagem continuamente
kubectl get pods -n "$NS" --watch

# Deployments, StatefulSets, DaemonSets, Jobs e CronJobs
kubectl get deployment,statefulset,daemonset,job,cronjob -n "$NS"

# Services, EndpointSlices e Ingresses
kubectl get service,endpointslice,ingress -n "$NS"

# Eventos recentes do cluster
kubectl get events -A --sort-by='.metadata.creationTimestamp'

# Eventos apenas de um namespace
kubectl get events -n "$NS" --sort-by='.metadata.creationTimestamp'
```

Filtrar por label ou campo:

```bash
kubectl get pods -n "$NS" --show-labels
kubectl get pods -n "$NS" -l app="$APP"
kubectl get pods -A --field-selector=status.phase=Pending
kubectl get pods -A --field-selector=status.phase=Failed
kubectl get events -n "$NS" --field-selector=type=Warning
```

## Inspecionar recursos

```bash
# Descrição, estado, condições e eventos relacionados
kubectl describe pod POD -n "$NS"
kubectl describe deployment DEPLOYMENT -n "$NS"
kubectl describe service SERVICE -n "$NS"
kubectl describe node NODE

# Manifesto efetivamente armazenado na API
kubectl get pod POD -n "$NS" -o yaml
kubectl get deployment DEPLOYMENT -n "$NS" -o yaml
kubectl get service SERVICE -n "$NS" -o yaml

# JSON compacto
kubectl get pod POD -n "$NS" -o json

# Imagem usada por cada container do Pod
kubectl get pod POD -n "$NS" \
  -o jsonpath='{range .spec.containers[*]}{.name}{" => "}{.image}{"\n"}{end}'

# Controlador proprietário do Pod
kubectl get pod POD -n "$NS" \
  -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

## Logs

```bash
# Logs atuais
kubectl logs POD -n "$NS"

# Container específico de um Pod com múltiplos containers
kubectl logs POD -n "$NS" -c CONTAINER

# Acompanhar em tempo real
kubectl logs -f POD -n "$NS" -c CONTAINER

# Últimas 200 linhas e somente a última hora
kubectl logs POD -n "$NS" --tail=200 --since=1h

# Logs da instância anterior de um container que reiniciou
kubectl logs POD -n "$NS" -c CONTAINER --previous

# Todos os containers, incluindo init containers quando aplicável
kubectl logs POD -n "$NS" --all-containers --prefix

# Logs dos Pods selecionados por label
kubectl logs -n "$NS" -l app="$APP" \
  --all-containers --prefix --tail=100

# Logs de um Deployment
kubectl logs -n "$NS" deployment/DEPLOYMENT \
  --all-containers --prefix --tail=200
```

## Exec, attach, cópia e acesso local

Abrir um novo processo dentro do container:

```bash
kubectl exec -it POD -n "$NS" -- sh
kubectl exec -it POD -n "$NS" -c CONTAINER -- bash
kubectl exec POD -n "$NS" -- env
kubectl exec POD -n "$NS" -- cat /etc/resolv.conf
```

`attach` conecta o terminal ao processo que já está executando no container. Ele não cria um novo shell:

```bash
kubectl attach -it POD -n "$NS" -c CONTAINER
```

A sequência padrão para desanexar sem encerrar o processo é `Ctrl+P`, depois `Ctrl+Q`. Isso só funciona adequadamente quando o processo principal aceita entrada pelo terminal.

Copiar arquivos:

```bash
# Máquina local para o container
kubectl cp ./arquivo.txt "$NS/POD:/tmp/arquivo.txt" -c CONTAINER

# Container para a máquina local
kubectl cp "$NS/POD:/var/log/app.log" ./app.log -c CONTAINER
```

O comando `kubectl cp` depende de `tar` dentro do container. Para imagens minimalistas sem `tar`, use `kubectl exec` com redirecionamento ou um container de depuração.

Encaminhar uma porta temporariamente:

```bash
kubectl port-forward -n "$NS" pod/POD 8080:8080
kubectl port-forward -n "$NS" deployment/DEPLOYMENT 8080:8080
kubectl port-forward -n "$NS" service/SERVICE 8080:80
```

## Depuração com container efêmero

Quando a imagem não possui `sh`, `curl`, `ps` ou outras ferramentas:

```bash
# Adicionar container efêmero ao Pod existente
kubectl debug -it pod/POD -n "$NS" \
  --image=ubuntu:latest --target=CONTAINER

# Criar uma cópia do Pod para depuração
kubectl debug pod/POD -n "$NS" -it \
  --image=ubuntu:latest --copy-to=POD-debug --share-processes

# Abrir ambiente de depuração no nó; filesystem do host fica em /host
kubectl debug node/NODE -it --image=ubuntu:latest --profile=sysadmin
```

Remova o Pod de depuração ao terminar:

```bash
kubectl delete pod POD-debug -n "$NS"
kubectl get pods -A | grep node-debugger
```

## Deployments, StatefulSets e DaemonSets

```bash
# Estado e histórico do rollout
kubectl rollout status deployment/DEPLOYMENT -n "$NS" --timeout=5m
kubectl rollout history deployment/DEPLOYMENT -n "$NS"

# Reiniciar Pods gerenciados sem remover o Deployment
kubectl rollout restart deployment/DEPLOYMENT -n "$NS"
kubectl rollout restart statefulset/STATEFULSET -n "$NS"
kubectl rollout restart daemonset/DAEMONSET -n "$NS"

# Pausar e retomar um Deployment
kubectl rollout pause deployment/DEPLOYMENT -n "$NS"
kubectl rollout resume deployment/DEPLOYMENT -n "$NS"

# Voltar à revisão anterior ou a uma revisão específica
kubectl rollout undo deployment/DEPLOYMENT -n "$NS"
kubectl rollout undo deployment/DEPLOYMENT -n "$NS" --to-revision=2

# Alterar quantidade de réplicas
kubectl scale deployment/DEPLOYMENT -n "$NS" --replicas=3

# Alterar imagem de um container
kubectl set image deployment/DEPLOYMENT -n "$NS" \
  CONTAINER=REGISTRY/IMAGEM:TAG

# Alterar/adicionar variável de ambiente
kubectl set env deployment/DEPLOYMENT -n "$NS" CHAVE=VALOR

# Aguardar disponibilidade
kubectl wait -n "$NS" --for=condition=Available \
  deployment/DEPLOYMENT --timeout=5m
```

Para “forçar” um novo rollout sem mudar a imagem, prefira `kubectl rollout restart`. Excluir Pods diretamente também provoca recriação quando eles são controlados por Deployment, StatefulSet ou DaemonSet, mas é menos expressivo.

## Services e conectividade

Um Service não executa processo e, portanto, não existe “restart de Service”. Quando o tráfego está quebrado:

1. confira o seletor do Service;
2. confira labels e readiness dos Pods;
3. confira os EndpointSlices;
4. reinicie o Deployment/StatefulSet que fornece os endpoints;
5. remova e reaplique o Service somente se o objeto estiver incorreto.

```bash
kubectl get service SERVICE -n "$NS" -o wide
kubectl describe service SERVICE -n "$NS"

# Seletor configurado no Service
kubectl get service SERVICE -n "$NS" -o jsonpath='{.spec.selector}{"\n"}'

# EndpointSlices associados ao Service
kubectl get endpointslice -n "$NS" \
  -l kubernetes.io/service-name=SERVICE -o wide

# Compatibilidade com a API Endpoints tradicional
kubectl get endpoints SERVICE -n "$NS" -o yaml

# Testar DNS e HTTP de dentro do cluster
kubectl run netcheck -n "$NS" --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -v http://SERVICE.NAMESPACE.svc.cluster.local:PORTA/

# Criar um Service para um Deployment existente
kubectl expose deployment DEPLOYMENT -n "$NS" \
  --name=SERVICE --type=ClusterIP --port=80 --target-port=8080
```

Remover e reaplicar um Service:

```bash
kubectl delete service SERVICE -n "$NS" --ignore-not-found --wait=false
kubectl apply -f service.yaml
```

> A recriação pode alterar `clusterIP`, `nodePort` ou endereço de LoadBalancer quando esses valores não estão fixados no manifesto. Normalmente é melhor corrigir e aplicar o manifesto sem excluir o Service.

## Aplicar, comparar e editar manifests

```bash
# Ver a diferença sem alterar o cluster
kubectl diff -f recurso.yaml

# Validar no servidor sem persistir
kubectl apply --dry-run=server -f recurso.yaml

# Aplicar declarativamente
kubectl apply -f recurso.yaml
kubectl apply -f manifests/

# Editar o objeto ao vivo
KUBE_EDITOR=nano kubectl edit deployment DEPLOYMENT -n "$NS"

# Patch simples
kubectl patch deployment DEPLOYMENT -n "$NS" --type=merge \
  -p '{"spec":{"replicas":2}}'

# Adicionar ou substituir label/annotation
kubectl label deployment DEPLOYMENT -n "$NS" ambiente=producao --overwrite
kubectl annotate deployment DEPLOYMENT -n "$NS" motivo="manutencao" --overwrite

# Remover label/annotation: hífen no final do nome
kubectl label deployment DEPLOYMENT -n "$NS" ambiente-
kubectl annotate deployment DEPLOYMENT -n "$NS" motivo-
```

Evite usar `kubectl edit` como única fonte de configuração. Depois de uma alteração emergencial, replique a mudança no manifesto versionado.

## Remoção normal e remoção forçada

### Pod

Remoção normal, respeitando o período de encerramento:

```bash
kubectl delete pod POD -n "$NS" --wait=true --timeout=2m
```

Remoção imediata, somente quando o Pod estiver comprovadamente preso:

```bash
kubectl delete pod POD -n "$NS" \
  --grace-period=0 --force --wait=false
```

Remover Pods por label para o controlador recriá-los:

```bash
kubectl delete pod -n "$NS" -l app="$APP"
```

> `--force` remove o objeto da API sem confirmar que o processo terminou no nó. Em StatefulSets, bancos de dados, filas e volumes compartilhados isso pode criar duas instâncias com a mesma identidade e causar corrupção. Use somente como último recurso.

### Deployment

Excluir Deployment e dependentes, aguardando a remoção:

```bash
kubectl delete deployment DEPLOYMENT -n "$NS" \
  --cascade=foreground --wait=true --timeout=5m
```

Solicitar exclusão em background e continuar imediatamente:

```bash
kubectl delete deployment DEPLOYMENT -n "$NS" \
  --cascade=background --wait=false
```

Excluir o controlador e preservar ReplicaSets/Pods órfãos:

```bash
kubectl delete deployment DEPLOYMENT -n "$NS" \
  --cascade=orphan --wait=false
```

Na maioria dos casos não exclua o Deployment para reiniciar a aplicação; use:

```bash
kubectl rollout restart deployment/DEPLOYMENT -n "$NS"
```

### Service

Service não possui encerramento gracioso como um Pod. Para remover:

```bash
kubectl delete service SERVICE -n "$NS" --ignore-not-found --wait=false
```

Reaplique imediatamente o manifesto se o Service ainda for necessário:

```bash
kubectl apply -f service.yaml
```

### Substituição forçada por manifesto

```bash
kubectl replace --force -f recurso.yaml
```

Esse comando exclui e recria o recurso, provocando indisponibilidade e possivelmente mudando identidades, UIDs, IPs ou dependentes. Use apenas quando um campo imutável realmente exigir recriação.

### Finalizers presos — último recurso

Primeiro descubra o finalizer e o motivo do bloqueio:

```bash
kubectl get pod POD -n "$NS" -o jsonpath='{.metadata.finalizers}{"\n"}'
kubectl describe pod POD -n "$NS"
```

Remover finalizers manualmente ignora a limpeza do controlador:

```bash
kubectl patch pod POD -n "$NS" --type=merge \
  -p '{"metadata":{"finalizers":[]}}'
```

Não faça isso em PVC, PV, Namespace ou recursos de operadores sem entender a rotina de limpeza e o impacto nos dados.

## ConfigMaps e Secrets

```bash
kubectl get configmap -n "$NS"
kubectl describe configmap CONFIGMAP -n "$NS"
kubectl get configmap CONFIGMAP -n "$NS" -o yaml

# Criar/atualizar ConfigMap declarativamente
kubectl create configmap CONFIGMAP -n "$NS" \
  --from-file=app.conf --dry-run=client -o yaml | kubectl apply -f -

# Criar/atualizar Secret a partir de arquivo
kubectl create secret generic SECRET -n "$NS" \
  --from-file=chave=./arquivo-secreto \
  --dry-run=client -o yaml | kubectl apply -f -

# Ver chaves existentes sem imprimir valores
kubectl get secret SECRET -n "$NS" \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'

# Decodificar conscientemente um valor
kubectl get secret SECRET -n "$NS" \
  -o jsonpath='{.data.CHAVE}' | base64 --decode; echo
```

Evite passar segredos por `--from-literal` em terminais compartilhados, pois o valor pode ficar no histórico do shell.

## RBAC, ServiceAccounts e tokens

```bash
# Identidade atual
kubectl auth whoami

# Verificar uma permissão
kubectl auth can-i get pods -n "$NS"
kubectl auth can-i delete deployments -n "$NS"
kubectl auth can-i '*' '*' --all-namespaces

# Listar permissões no namespace
kubectl auth can-i --list -n "$NS"

# Simular uma ServiceAccount
kubectl auth can-i list pods -A \
  --as=system:serviceaccount:NAMESPACE:SERVICE_ACCOUNT

# ServiceAccounts e bindings
kubectl get serviceaccount -A
kubectl get role,rolebinding -A
kubectl get clusterrole,clusterrolebinding

# Token temporário de ServiceAccount
kubectl create token SERVICE_ACCOUNT -n "$NS" --duration=1h
```

## Jobs e CronJobs

```bash
kubectl get job,cronjob -n "$NS"
kubectl describe job JOB -n "$NS"
kubectl logs -n "$NS" job/JOB --all-containers

# Criar execução manual a partir de CronJob
kubectl create job -n "$NS" \
  --from=cronjob/CRONJOB "CRONJOB-manual-$(date +%s)"

# Suspender e retomar CronJob
kubectl patch cronjob CRONJOB -n "$NS" --type=merge \
  -p '{"spec":{"suspend":true}}'
kubectl patch cronjob CRONJOB -n "$NS" --type=merge \
  -p '{"spec":{"suspend":false}}'

# Excluir Job e Pods dependentes
kubectl delete job JOB -n "$NS" --cascade=foreground
```

## Armazenamento

```bash
kubectl get storageclass
kubectl get persistentvolume
kubectl get persistentvolumeclaim -A
kubectl describe pvc PVC -n "$NS"
kubectl get pod POD -n "$NS" \
  -o jsonpath='{range .spec.volumes[*]}{.name}{" => "}{.persistentVolumeClaim.claimName}{"\n"}{end}'
```

Antes de excluir PVC/PV, confirme `persistentVolumeReclaimPolicy`, backups e se algum Pod ainda monta o volume.

## Nós e manutenção

```bash
kubectl get nodes -o wide
kubectl describe node NODE
kubectl get pods -A --field-selector=spec.nodeName=NODE -o wide

# Impedir novos agendamentos
kubectl cordon NODE

# Evacuar workloads; apaga dados de emptyDir
kubectl drain NODE \
  --ignore-daemonsets --delete-emptydir-data --timeout=10m

# Permitir agendamentos novamente
kubectl uncordon NODE

# Taints
kubectl taint nodes NODE chave=valor:NoSchedule
kubectl taint nodes NODE chave:NoSchedule-
```

> Este projeto cria um cluster de nó único. `cordon`/`drain` no único nó deixa workloads sem lugar para executar e pode indisponibilizar o Dashboard.

Uso de CPU/memória, somente se Metrics Server estiver instalado:

```bash
kubectl top nodes
kubectl top pods -A
kubectl top pods -n "$NS" --containers
```

## Esperas e condições úteis

```bash
kubectl wait --for=condition=Ready node --all --timeout=5m
kubectl wait -n "$NS" --for=condition=Ready pod/POD --timeout=5m
kubectl wait -n "$NS" --for=condition=Available \
  deployment/DEPLOYMENT --timeout=5m
kubectl wait -n "$NS" --for=delete pod/POD --timeout=2m
```

## Diagnóstico do nó, kubelet e containerd

Execute no servidor Ubuntu:

```bash
sudo systemctl status containerd kubelet --no-pager
sudo journalctl -u containerd -u kubelet -n 200 --no-pager
sudo journalctl -u kubelet --since "30 minutes ago" --no-pager

# CRI/containerd
sudo crictl info
sudo crictl pods
sudo crictl ps -a
sudo crictl images
sudo crictl logs CONTAINER_ID
sudo crictl inspect CONTAINER_ID
sudo crictl inspectp POD_SANDBOX_ID

# Runtime diretamente
sudo ctr --namespace k8s.io containers list
sudo ctr --namespace k8s.io images list

# Rede e portas
sudo ss -lntup
sudo ufw status numbered
sudo ip route
sudo ip address
```

Kubeadm e certificados:

```bash
sudo kubeadm version
sudo kubeadm certs check-expiration
sudo kubeadm config images list
```

Não execute `kubeadm reset` como tentativa genérica de correção: ele desmonta o estado local do cluster.

## Dashboard Headlamp deste projeto

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
export DASHBOARD_NS=kubernetes-dashboard

# Estado geral
kubectl get deployment,replicaset,pod,service \
  -n "$DASHBOARD_NS" -o wide

# Rollout, eventos e logs
kubectl rollout status deployment/headlamp \
  -n "$DASHBOARD_NS" --timeout=5m
kubectl get events -n "$DASHBOARD_NS" \
  --sort-by='.metadata.creationTimestamp'
kubectl logs -n "$DASHBOARD_NS" deployment/headlamp \
  --all-containers --prefix --tail=200

# NodePort configurado
kubectl get service headlamp -n "$DASHBOARD_NS" \
  -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}{"\n"}'

# Reinício normal
kubectl rollout restart deployment/headlamp -n "$DASHBOARD_NS"

# Tokens temporários criados pelo instalador
sudo k8s-dashboard-token viewer 8h
sudo k8s-dashboard-token admin 1h

# Teste HTTPS local usando a CA do projeto
curl --cacert /etc/kubernetes/pki/headlamp/ca.crt \
  https://IP_DO_NO:30443/
```

Reconciliar somente o Dashboard usando `cluster.env`:

```bash
cd /CAMINHO/DO/REPOSITORIO/kubernetes
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/60-install-dashboard.sh --check
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/60-install-dashboard.sh
```

Remover forçadamente apenas o workload Headlamp para o script recriá-lo, preservando Service, certificado e RBAC:

```bash
kubectl delete deployment headlamp -n "$DASHBOARD_NS" \
  --cascade=background --wait=false --ignore-not-found

kubectl delete replicaset -n "$DASHBOARD_NS" \
  -l app.kubernetes.io/name=headlamp \
  --cascade=background --wait=false --ignore-not-found

kubectl delete pod -n "$DASHBOARD_NS" \
  -l app.kubernetes.io/name=headlamp \
  --grace-period=0 --force --wait=false --ignore-not-found

sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/60-install-dashboard.sh
```

Prefira executar o script: ele valida que o recurso pertence ao instalador, limpa rollouts inconsistentes e faz a verificação pós-instalação.

## Coleta para diagnóstico

```bash
# Visão ampla sem alterar o cluster
kubectl cluster-info dump --output-directory=./cluster-dump

# Estado essencial em texto
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by='.metadata.creationTimestamp'
kubectl get deployment,statefulset,daemonset -A
kubectl get service,endpointslice -A
```

Revise o conteúdo antes de compartilhar: dumps, manifests, logs e Secrets podem conter nomes internos, endereços, tokens ou credenciais.

## Referências oficiais

- [Referência rápida do kubectl](https://kubernetes.io/docs/reference/kubectl/quick-reference/)
- [Referência completa dos comandos kubectl](https://kubernetes.io/docs/reference/kubectl/generated/)
- [`kubectl attach`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_attach/)
- [`kubectl delete` e riscos de `--force`](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_delete/)
- [Depuração de Pods em execução](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/)
- [Depuração de Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
