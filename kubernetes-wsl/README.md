# Kubernetes local no WSL 2 — Ubuntu 26.04

Esta pasta cria um cluster Kubernetes de nó único dentro do **WSL 2 com Ubuntu 26.04**, usando `kubeadm`, `containerd`, Flannel, Headlamp, Gateway API e Envoy Gateway. A variante foi desenhada para um notebook corporativo:

- usa a rede `mirrored` do WSL 2 para melhor compatibilidade com VPN, DNS e proxy corporativos;
- não instala, ativa ou configura UFW;
- não usa OIDC, Keycloak ou arquivo de secrets;
- não exige colar tokens no Headlamp;
- não depende de Docker Desktop;
- não usa PowerShell;
- mantém Headlamp e Envoy em `ClusterIP`, sem NodePort nem porta em `0.0.0.0`;
- requer privilégio administrativo no Windows apenas se o WSL ainda precisar ser habilitado pela empresa.

O `sudo` dentro do Ubuntu continua necessário para instalar pacotes e executar o kubelet. Esse privilégio Linux é separado da conta administrativa do Windows.

## Como funciona

```text
navegador no Windows
  https://localhost:30443
           |
           | loopback bidirecional da rede mirrored do WSL 2
           v
systemd: kubectl port-forward --address=127.0.0.1
           |
           v
Service ClusterIP do Headlamp
           |
           v
Headlamp Pod --unsafe-use-service-account-token
           |
           v
ServiceAccount headlamp -> cluster-admin (somente laboratório local)
```

O modo automático do Headlamp entrega privilégios administrativos a qualquer pessoa que consiga alcançar a interface. Por isso esta automação mantém o Service como `ClusterIP` e prende seu túnel a `127.0.0.1`. Não publique essa porta com `netsh portproxy`, proxy reverso, túnel ou regra de rede.

O tráfego das aplicações usa um segundo caminho, independente e também local:

```text
cliente no Windows -> http://localhost:30080
  -> systemd: kubectl port-forward --address=127.0.0.1
  -> Service ClusterIP do Envoy
  -> Gateway/HTTPRoute ou GRPCRoute
  -> Service da aplicação
```

O túnel do Gateway é instalado **fechado por padrão**. Criar rotas não publica automaticamente a porta no Windows.

## 1. Preparar o WSL 2 pelo CMD

Abra o **Prompt de Comando (CMD)**. Não use PowerShell.

Confira o ambiente:

```bat
wsl.exe --version
wsl.exe --list --verbose
```

A distribuição precisa aparecer com `VERSION 2`. A rede mirrored requer Windows 11
22H2 ou superior e uma versão atual do WSL. Se o WSL ou o Ubuntu 26.04 ainda não
existirem, os comandos abaixo normalmente exigem um CMD executado como Administrador
e podem ser bloqueados pela política corporativa:

```bat
wsl.exe --update
wsl.exe --install -d Ubuntu-26.04
wsl.exe --set-version Ubuntu-26.04 2
```

Se a política impedir esses comandos, solicite à TI apenas a habilitação do WSL 2 e a instalação da distribuição Ubuntu 26.04. O restante não precisa de administrador do Windows.

Feche Rancher Desktop, Docker Desktop ou outro Kubernetes local antes do bootstrap. Distribuições WSL podem compartilhar portas, e o preflight interrompe com diagnóstico se `6443` já estiver ocupada.

### Rede mirrored e recursos

O arquivo [windows/.wslconfig.example](windows/.wslconfig.example) habilita
`networkingMode=mirrored`, DNS tunneling, proxy automático e tempos maiores para
detectar o proxy corporativo. `hostAddressLoopback` permanece desativado e nenhuma
porta é ignorada. Copiá-lo para `%UserProfile%\.wslconfig` afeta **todas** as
distribuições WSL 2 do usuário:

```bat
copy windows\.wslconfig.example "%UserProfile%\.wslconfig"
windows\05-apply-mirrored-network.cmd Ubuntu-26.04
```

O script usa `wsl.exe --shutdown` porque `networkingMode` é global; salve o trabalho
de todas as distribuições antes de executá-lo. Ele não usa PowerShell e não altera
firewall. Revise memória e CPUs antes de copiar. O mínimo validado é 2 CPUs, 2 GB
de RAM e 10 GB livres; 4 CPUs e 6 GB de RAM deixam o laboratório mais confortável.

## 2. Habilitar systemd no Ubuntu

Abra o Ubuntu 26.04 e entre na pasta `kubernetes-wsl`. Projetos Linux ficam mais rápidos no filesystem do WSL (`~/...`) do que em `/mnt/c`:

```bash
cp -a /mnt/c/CAMINHO/DO/REPOSITORIO/kubernetes-wsl ~/kubernetes-wsl
cd ~/kubernetes-wsl
sudo bash prepare-wsl.sh
```

O preparador preserva as demais seções de `/etc/wsl.conf`, instala os pacotes de systemd que estiverem ausentes e define somente `systemd=true`. Depois, no CMD do Windows:

```bat
wsl.exe --terminate Ubuntu-26.04
```

Ou use o utilitário fornecido:

```bat
windows\10-restart-wsl.cmd Ubuntu-26.04
```

Abra novamente o Ubuntu e confirme:

```bash
systemctl is-system-running
```

Os estados `running` e `degraded` são aceitos; `degraded` pode refletir serviços opcionais da imagem WSL.

## 3. Instalar o cluster

Dentro do Ubuntu:

```bash
cd ~/kubernetes-wsl
cp .env.example cluster.env
nano cluster.env
sudo bash install-all.sh cluster.env
```

Não existe `oidc-secrets.env`. Para a instalação padrão, não é necessário alterar `cluster.env`.

O `cluster.env` fica na raiz desta pasta, ao lado de `install-all.sh`. Ele é
local e ignorado pelo Git. Se o projeto estiver em
`/home/USUARIO/.../kubernetes-wsl`, esse será o caminho Linux; se estiver no
disco `C:`, o WSL o enxergará em `/mnt/c/.../kubernetes-wsl/cluster.env`.

O instalador é reconciliador: ao ser executado novamente, verifica cada etapa antes de alterá-la. Um cluster que já tenha `/etc/kubernetes/admin.conf` nunca é resetado automaticamente. O reparo com `kubeadm reset` é limitado a um bootstrap parcial sem `admin.conf`, após backup de `/etc/kubernetes`.

### Contingência para downloads bloqueados

No próprio Ubuntu WSL do notebook corporativo, execute:

```bash
bash setup-offline-cache.sh
sudo bash install-all.sh cluster.env
```

`setup-offline-cache.sh` faz tudo no Linux: baixa o bundle publicado pelo S3
para `/tmp`, valida o SHA-256, extrai diretamente na pasta `offline-cache` do
projeto, remove o download temporário e cria `cluster.env` se ele ainda não
existir. O arquivo fica configurado com `ARTIFACT_MODE="offline"`. Nesse modo, os
scripts não consultam a chave nem o repositório `pkgs.k8s.io`; se os pacotes já
estiverem corretamente instalados por `dpkg`, a etapa Kubernetes também não chama
o APT. Um repositório Kubernetes anteriormente habilitado é renomeado para
`kubernetes.list.disabled`.

Ao instalar os grupos `.deb` do bundle, versões já instaladas que sejam iguais ou
mais novas são preservadas. O APT recebe temporariamente uma lista de fontes vazia,
portanto não consulta a rede, não rebaixa correções mais recentes do Ubuntu e falha
de forma explícita se o cache não contiver uma dependência necessária.

O bundle contém pacotes `.deb` e suas dependências, chave do repositório
Kubernetes, Helm, manifesto do Flannel e charts do Envoy Gateway. Ele não
contém imagens de contêiner. Portanto, o notebook ainda precisa alcançar os
registries usados por kubeadm, Flannel, Headlamp e Envoy.

Para manter ou republicar o bundle, use o fluxo isolado em
[`offline-bundle-builder/`](offline-bundle-builder/HELP.md). O gerador não é
necessário no notebook corporativo.

### Por que `NODE_IP` é fixo

No modo mirrored, as interfaces do Windows são refletidas no Linux e os endereços
podem mudar com DHCP, Wi-Fi e VPN. A automação não usa esses endereços mutáveis como
identidade do nó: cria `10.254.254.1/32` na interface loopback por meio de systemd e
usa esse endereço somente dentro do WSL no kubelet e no API Server. Assim,
`wsl.exe --shutdown`, reinícios do Windows e mudanças de VPN não invalidam o cluster.

Se `10.254.254.1` conflitar com VPN ou rede corporativa, escolha outro IPv4 privado em `cluster.env` **antes da primeira instalação**. `NODE_IP`, `NODE_NAME`, `POD_NETWORK_CIDR` e `SERVICE_CIDR` são tratados como imutáveis depois do bootstrap.

### Swap do WSL

O script não executa `swapoff`, não edita `/etc/fstab` e não altera `.wslconfig`. O kubelet recebe:

```yaml
failSwapOn: false
memorySwap:
  swapBehavior: NoSwap
```

Com isso, serviços Linux podem usar o swap gerenciado pelo WSL, mas os Pods continuam sem acesso a swap.

## 4. Abrir e fechar o Headlamp sem token

Após a instalação, abra no Windows:

```text
https://localhost:30443/?lng=pt
```

No CMD, primeiro habilite o encaminhamento local e depois abra o navegador:

```bat
windows\20-open-cluster-ports.cmd Ubuntu-26.04 30443
windows\40-open-headlamp.cmd 30443
```

Não há tela de OIDC nem necessidade de gerar tokens periódicos. O Headlamp usa a ServiceAccount interna `headlamp`, ligada ao `cluster-admin` apenas para este laboratório local.

Ao terminar, feche e desabilite persistentemente o encaminhamento. O cluster continuará funcionando dentro do WSL:

```bat
windows\80-close-cluster-ports.cmd Ubuntu-26.04 30443
```

Consulte [windows/README.md](windows/README.md) para a sequência completa, parâmetros e diagnóstico de cada utilitário CMD.

### Remover o aviso do certificado

O certificado inclui `localhost` e `127.0.0.1`. Para confiar na CA no repositório do **usuário atual** do Windows, sem administrador e sem PowerShell:

```bat
windows\30-trust-headlamp-ca.cmd Ubuntu-26.04
```

O script usa `certutil.exe -user`, importa somente a CA pública e apaga a cópia temporária. A chave privada permanece no Linux em `/etc/kubernetes/pki/headlamp/ca.key`.

Para remover essa confiança depois, também sem administrador:

```bat
windows\90-untrust-headlamp-ca.cmd
```

## 5. Usar Gateway API e Envoy Gateway

O instalador cria `GatewayClass/envoy-wsl` e `Gateway/gateway-system/wsl-gateway`. O listener HTTP usa a porta interna `8080`, aceita rotas de todos os namespaces e mantém o Service Envoy como `ClusterIP`. Referências de uma rota para backends em outro namespace continuam bloqueadas até existir um `ReferenceGrant` explícito no namespace do backend.

No Headlamp, o menu **Gateway (beta)** passa a mostrar objetos reais do cluster:

- `Gateways`, `Classes de Gateway`, `Rotas HTTP` e `Rotas GRPC` usam Gateway API `v1`;
- `Concessões de Referência` mostra `ReferenceGrant v1`;
- `BackendTLSPolicies` usa Gateway API `v1` para TLS entre Envoy e backend;
- `BackendTrafficPolicies` usa a extensão `gateway.envoyproxy.io/v1alpha1` para circuit breaker, retry, rate limit e outras políticas do Envoy.

O rótulo “beta” é da área do Headlamp. Gateway API `v1.6.1` está no canal **Standard**, e os tipos Gateway API acima são servidos em `v1`. Envoy Gateway `v1.9.1` e Helm `v4.3.0` são releases estáveis. A exceção deliberada é `BackendTrafficPolicy`: o Envoy Gateway está estável, mas essa API específica ainda é `v1alpha1`; por isso nenhum exemplo dela é aplicado automaticamente.

O diretório [manifests/gateway/examples](manifests/gateway/examples/README.md) contém exemplos opt-in de `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`, `BackendTLSPolicy` e `BackendTrafficPolicy`. O instalador não cria aplicação de demonstração nem associa o Headlamp ao Gateway.

Para abrir o acesso HTTP de aplicações no Windows:

```bat
windows\25-open-gateway-port.cmd Ubuntu-26.04 30080
windows\45-test-gateway.cmd 30080
```

HTTP `404` significa que o Envoy respondeu, mas nenhuma rota combinou com `/`. Depois de aplicar o exemplo `HTTPRoute`, teste o caminho configurado:

```bat
curl.exe http://localhost:30080/app
```

Feche persistentemente ao terminar:

```bat
windows\75-close-gateway-port.cmd Ubuntu-26.04 30080
```

Isso para apenas o port-forward. O Gateway e as aplicações continuam internos ao cluster.

## O que é instalado

- Kubernetes `v1.36` pelos pacotes oficiais, via `pkgs.k8s.io` ou cache local offline;
- `containerd` e `runc` do Ubuntu, com cgroups `systemd`;
- `kubeadm`, `kubelet`, `kubectl`, CNI plugins e `crictl`;
- Flannel `v0.28.8`, com manifesto validado por SHA-256;
- Helm `v4.3.0`, com pacote validado por SHA-256;
- Gateway API `v1.6.1`, canal Standard;
- Envoy Gateway `v1.9.1`, com charts OCI fixados e validados por SHA-256;
- `GatewayClass/envoy-wsl`, `Gateway/gateway-system/wsl-gateway` e dataplane Envoy `ClusterIP`;
- Headlamp `v0.45.0` com HTTPS no backend;
- serviço systemd para o IPv4 estável do nó;
- serviço systemd para o encaminhamento HTTPS em `127.0.0.1`;
- serviço systemd, desabilitado por padrão, para o Envoy em `127.0.0.1`.

Não são instalados ou configurados: UFW, OIDC, Keycloak, Ingress NGINX, MetalLB, LoadBalancer, NodePort, Docker Desktop ou componentes no Windows.

## Configuração

| Variável | Padrão | Uso |
|---|---:|---|
| `KUBERNETES_MINOR` | `v1.36` | canal minor do repositório Kubernetes |
| `NODE_IP` | `10.254.254.1` | endereço estável interno criado em `lo` |
| `NODE_NAME` | `kubernetes-wsl` | nome fixo do nó |
| `ADMIN_USER` | usuário que chamou `sudo` | recebe `~/.kube/config` e a CA pública |
| `CLUSTER_OPERATION_TIMEOUT` | `20m` | espera de rollouts, CRDs, rede, Gateway e acessos locais |
| `KUBEADM_INIT_TIMEOUT` | `20m` | espera interna e externa da etapa 40/control plane |
| `KUBERNETES_REQUEST_TIMEOUT_SECONDS` | `30` | limite de cada consulta curta à API/CRI |
| `ARTIFACT_CONNECT_TIMEOUT_SECONDS` | `60` | limite para estabelecer conexões de download |
| `ARTIFACT_RETRY_ATTEMPTS` | `6` | tentativas de download e pull de imagem |
| `ARTIFACT_RETRY_DELAY_SECONDS` | `10` | intervalo entre tentativas de artefatos |
| `POD_NETWORK_CIDR` | `10.244.0.0/16` | rede Flannel |
| `SERVICE_CIDR` | `10.96.0.0/12` | rede dos Services |
| `DASHBOARD_LOCAL_PORT` | `30443` | porta local do Windows/WSL |
| `DASHBOARD_DEFAULT_LANGUAGE` | `pt` | idioma do link do Headlamp |
| `DASHBOARD_ROLLOUT_TIMEOUT` | `20m` | espera específica pelo Headlamp |
| `HELM_VERSION` | `v4.3.0` | versão reproduzível usada para os charts OCI |
| `GATEWAY_API_VERSION` | `v1.6.1` | bundle Standard compatível com o Envoy Gateway fixado |
| `ENVOY_GATEWAY_VERSION` | `v1.9.1` | release estável do controlador e dataplane |
| `GATEWAY_CLASS_NAME` | `envoy-wsl` | classe selecionada pelas instâncias Gateway |
| `GATEWAY_NAMESPACE` / `GATEWAY_NAME` | `gateway-system` / `wsl-gateway` | Gateway HTTP base |
| `GATEWAY_LISTENER_PORT` | `8080` | porta interna do listener/Service Envoy |
| `GATEWAY_LOCAL_PORT` | `30080` | porta opcional em `127.0.0.1` para o Windows |
| `ARTIFACT_MODE` | `auto` | `auto`, `online` ou `offline`; `cache` é alias de `offline` |
| `ARTIFACT_CACHE_DIR` | `offline-cache` no projeto | cache local separado por arquitetura |
| `ALLOW_LOW_RESOURCES` | `false` | permite prosseguir abaixo dos mínimos |
| `AUTO_REPAIR_PARTIAL_CLUSTER` | `true` | repara somente bootstrap incompleto sem `admin.conf` |
| `BOOTSTRAP_LOG_DIR` | `/var/log/k8s-wsl-bootstrap` | diretório Linux dos transcripts de deploy e diagnóstico |
| `BOOTSTRAP_COLOR` | `auto` | cores no console: `auto`, `always` ou `never`; `NO_COLOR=1` também desativa |
| `DIAGNOSTIC_ON_ERROR` | `true` | executa o diagnóstico somente leitura quando o deploy falha |
| `DIAGNOSTIC_CHECK_TIMEOUT_SECONDS` | `45` | limite individual de cada check do diagnóstico |
| `DIAGNOSTIC_TAIL_LINES` | `100` | máximo de linhas por journal, evento ou log de Pod coletado |

## Operação diária

O cluster inicia quando a distribuição WSL é iniciada. Não é preciso executar o instalador novamente após reiniciar o Windows.

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n kubernetes-dashboard get deployment,pod,service
systemctl status containerd kubelet k8s-headlamp-local k8s-gateway-local --no-pager
kubectl get gatewayclass,gateway -A
kubectl get httproute,grpcroute,referencegrant,backendtlspolicy -A
```

Verificação completa:

```bash
cd ~/kubernetes-wsl
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/90-verify.sh
```

Reconciliar somente o Headlamp e o acesso local:

```bash
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/60-install-dashboard.sh
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/70-configure-local-access.sh
```

Reconciliar somente Gateway API, Envoy e o mecanismo de acesso local:

```bash
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/52-install-helm.sh
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/55-install-gateway.sh
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/75-configure-gateway-access.sh
```

Logs relevantes:

```bash
# Transcript completo do deploy mais recente
sudo less /var/log/k8s-wsl-bootstrap/latest-deploy.log

# Diagnóstico consolidado baseado no cluster.env (não altera o cluster)
sudo bash diagnose.sh cluster.env
sudo less /var/log/k8s-wsl-bootstrap/latest-diagnostic.log

sudo journalctl -u containerd -u kubelet -u k8s-headlamp-local -u k8s-gateway-local -n 200 --no-pager
kubectl -n kubernetes-dashboard logs deployment/headlamp --tail=200
kubectl -n envoy-gateway-system logs deployment/envoy-gateway --tail=200
```

Cada execução de `install-all.sh` mostra um cabeçalho com o contexto operacional,
separa visualmente as 12 etapas e termina com um resumo do resultado e da duração
de cada etapa. Em terminal interativo, sucesso, andamento, avisos e falhas recebem
cores e símbolos distintos. Para desativar as cores, use `NO_COLOR=1` ou configure
`BOOTSTRAP_COLOR=never`.

O arquivo `deploy-AAAAMMDD-HHMMSS-PID.log`, criado com modo `0600`, permanece em
texto puro, sem códigos ANSI. Cada registro contém data/hora, nível, componente,
estado e mensagem; cada linha de saída bruta de `apt`, `kubeadm`, Helm e `kubectl`
também recebe timestamp e o nível `OUTPUT`. O link `latest-deploy.log` aponta para
a execução mais recente.

Em caso de falha, o resumo destaca a etapa interrompida e o instalador executa uma
coleta somente leitura separada. O deploy referencia o caminho do relatório, e o
link `latest-diagnostic.log` oferece os checks, journals, Pods não saudáveis, logs
desses Pods e eventos Kubernetes do tipo `Warning`, sem misturar essas evidências
com a sequência principal do deploy.

`diagnose.sh` pode ser executado a qualquer momento. Ele carrega o mesmo
`cluster.env`, compara a configuração desejada com o estado real e retorna `0`
quando não encontra divergências ou `1` quando há algo pendente. O relatório
mostra somente campos operacionais selecionados e o fingerprint da configuração;
o conteúdo bruto do `cluster.env` não é copiado para o log.

Consulte também [KUBERNETES_COMMANDS.md](KUBERNETES_COMMANDS.md).

## Resetar o ambiente Kubernetes

`uninstall-all.sh` remove somente o estado e as configurações pertencentes a
este cluster. Antes de executar, veja o plano sem alterar o Linux:

```bash
cd ~/kubernetes-wsl
sudo bash uninstall-all.sh cluster.env --dry-run
```

Para confirmar a limpeza:

```bash
sudo bash uninstall-all.sh cluster.env --yes
```

O script executa `kubeadm reset`, para e desabilita o kubelet e os serviços
locais do projeto, remove o estado de etcd/kubelet/CNI/Flannel, interfaces
`flannel.1` e `cni0`, kubeconfigs reconhecidos como cópias deste cluster e todos
os containers, sandboxes e imagens registrados pelo CRI no containerd. A opção
`--yes` é obrigatória; não existe confirmação interativa que possa ser aceita
acidentalmente.

São preservados todos os pacotes APT, seus holds, `containerd`, sua configuração
geral e dados de outros namespaces, Helm, `offline-cache/`, backups e os logs de
auditoria. Portanto, comandos como `kubeadm`, `kubectl` e `crictl` continuam
instalados, embora não exista mais um cluster. Imagens de Docker/Rancher Desktop
fora do namespace Kubernetes também não são tocadas.

Cada execução gera um log `uninstall-AAAAMMDD-HHMMSS-PID.log` em
`/var/log/k8s-wsl-bootstrap`; o mais recente fica disponível por:

```bash
sudo less /var/log/k8s-wsl-bootstrap/latest-uninstall.log
```

A CA eventualmente importada no Windows é deliberadamente preservada. Para
removê-la do repositório do usuário Windows, execute separadamente
`windows\90-untrust-headlamp-ca.cmd` no CMD.

Depois do reset, o mesmo `cluster.env` pode recriar o laboratório:

```bash
sudo bash install-all.sh cluster.env
```

## Ambiente corporativo

- Rede mirrored: Windows e WSL usam `localhost` bidirecional, enquanto DNS tunneling, `autoProxy` e `bestEffortDnsParsing` melhoram a compatibilidade com VPN e resolução corporativa.
- VPN e proxy: se downloads de pacotes falharem, o bundle local pode assumir automaticamente; imagens continuam exigindo os registries.
- Cache local: gere-o em Ubuntu 26.04 da mesma arquitetura. Refaça o bundle ao mudar Kubernetes, Helm, Flannel ou Envoy Gateway; não versione os binários no Git.
- Proxy autenticado: prefira configuração corporativa de APT e variáveis de ambiente fornecidas pela TI; não versione credenciais em `cluster.env`.
- Política de execução: os scripts Windows são `.cmd`, não usam PowerShell e controlam o túnel por `wsl.exe`/systemd.
- Firewall: esta pasta não chama `ufw`, `netsh advfirewall` ou APIs do Windows Firewall.
- Exposição remota: deliberadamente não suportada. Headlamp e Gateway são alcançados do Windows apenas por túneis locais independentes.

## Diagnóstico

### Relatório completo do estado atual

```bash
cd ~/kubernetes-wsl
sudo bash diagnose.sh cluster.env
sudo less /var/log/k8s-wsl-bootstrap/latest-diagnostic.log
```

O relatório continua após uma falha para mostrar também erros dependentes nas
etapas seguintes. Isso ajuda a separar a causa inicial dos efeitos em Flannel,
DNS, Envoy e Headlamp.

### A etapa 40 demorou ou foi interrompida

Não execute `kubeadm reset` manualmente. Reexecute o instalador; a etapa 40 espera
até `KUBEADM_INIT_TIMEOUT`, preserva um control plane que ainda responda e só
repara automaticamente um bootstrap comprovadamente parcial:

```bash
sudo bash install-all.sh cluster.env
```

Se ainda falhar, consulte o log mantido pelo instalador e o kubelet:

```bash
sudo tail -n 200 /var/lib/k8s-wsl-bootstrap/kubeadm-init.log
sudo journalctl -u kubelet -n 200 --no-pager
```

### systemd não é PID 1

```bash
sudo bash prepare-wsl.sh
```

Depois, no CMD:

```bat
wsl.exe --terminate Ubuntu-26.04
```

### O Headlamp não abre

```bash
sudo systemctl restart k8s-headlamp-local
sudo systemctl status k8s-headlamp-local --no-pager
sudo journalctl -u k8s-headlamp-local -n 100 --no-pager
curl --cacert ~/.kube/headlamp-ca.crt https://127.0.0.1:30443/
```

Se a porta estiver ocupada, altere `DASHBOARD_LOCAL_PORT` no `cluster.env` e reexecute `install-all.sh`.

### Gateway responde `404`

Isso é normal sem uma `HTTPRoute` que combine com host e caminho. Confira os vínculos e condições:

```bash
kubectl get gatewayclass,gateway,httproute,grpcroute -A
kubectl describe gateway wsl-gateway -n gateway-system
kubectl describe httproute NOME -n NAMESPACE
```

Se a URL nem conectar, abra o túnel pelo CMD com `windows\25-open-gateway-port.cmd`. Para diagnóstico no WSL:

```bash
sudo systemctl status k8s-gateway-local --no-pager
sudo journalctl -u k8s-gateway-local -n 100 --no-pager
kubectl -n envoy-gateway-system logs deployment/envoy-gateway --tail=200
```

### Cluster não volta após reiniciar o WSL

```bash
ip address show dev lo
systemctl status k8s-wsl-node-ip containerd kubelet --no-pager
sudo journalctl -u k8s-wsl-node-ip -u kubelet -b --no-pager
```

O endereço configurado em `NODE_IP` deve aparecer como `/32` na interface `lo`.

## Referências oficiais

- [Configuração avançada do WSL](https://learn.microsoft.com/windows/wsl/wsl-config)
- [systemd no WSL](https://learn.microsoft.com/windows/wsl/systemd)
- [Rede do WSL](https://learn.microsoft.com/windows/wsl/networking)
- [Instalação do kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Gerenciamento de swap no Kubernetes](https://kubernetes.io/docs/concepts/cluster-administration/swap-memory-management/)
- [Headlamp em cluster](https://headlamp.dev/docs/latest/installation/in-cluster/)
- [Gateway API](https://gateway-api.sigs.k8s.io/)
- [Instalação Helm do Envoy Gateway](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [Matriz de compatibilidade do Envoy Gateway](https://gateway.envoyproxy.io/news/releases/matrix/)
