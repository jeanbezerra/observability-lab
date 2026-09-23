# Kubernetes local no WSL 2 — Ubuntu 26.04

Esta pasta cria um cluster Kubernetes de nó único dentro do **WSL 2 com Ubuntu 26.04**, usando `kubeadm`, `containerd`, Flannel e Headlamp. A variante foi desenhada para um notebook corporativo:

- não instala, ativa ou configura UFW;
- não usa OIDC, Keycloak ou arquivo de secrets;
- não exige colar tokens no Headlamp;
- não depende de Docker Desktop;
- não usa PowerShell;
- não expõe NodePort nem porta em `0.0.0.0`;
- requer privilégio administrativo no Windows apenas se o WSL ainda precisar ser habilitado pela empresa.

O `sudo` dentro do Ubuntu continua necessário para instalar pacotes e executar o kubelet. Esse privilégio Linux é separado da conta administrativa do Windows.

## Como funciona

```text
navegador no Windows
  https://localhost:30443
           |
           | encaminhamento localhost nativo do WSL 2
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

O modo automático do Headlamp entrega privilégios administrativos a qualquer pessoa que consiga alcançar a interface. Por isso esta automação mantém o Service como `ClusterIP` e prende o único túnel a `127.0.0.1`. Não publique essa porta com `netsh portproxy`, proxy reverso, túnel ou regra de rede.

## 1. Preparar o WSL 2 pelo CMD

Abra o **Prompt de Comando (CMD)**. Não use PowerShell.

Confira o ambiente:

```bat
wsl.exe --version
wsl.exe --list --verbose
```

A distribuição precisa aparecer com `VERSION 2`. Se o WSL ou o Ubuntu 26.04 ainda não existirem, os comandos abaixo normalmente exigem um CMD executado como Administrador e podem ser bloqueados pela política corporativa:

```bat
wsl.exe --update
wsl.exe --install -d Ubuntu-26.04
wsl.exe --set-version Ubuntu-26.04 2
```

Se a política impedir esses comandos, solicite à TI apenas a habilitação do WSL 2 e a instalação da distribuição Ubuntu 26.04. O restante não precisa de administrador do Windows.

Feche Rancher Desktop, Docker Desktop ou outro Kubernetes local antes do bootstrap. Distribuições WSL podem compartilhar portas, e o preflight interrompe com diagnóstico se `6443` já estiver ocupada.

### Recursos opcionais

O arquivo [windows/.wslconfig.example](windows/.wslconfig.example) traz uma configuração de referência. Copiá-lo para `%UserProfile%\.wslconfig` afeta **todas** as distribuições WSL 2 do usuário:

```bat
copy windows\.wslconfig.example "%UserProfile%\.wslconfig"
wsl.exe --shutdown
```

Revise memória e CPUs antes de copiar. O mínimo validado é 2 CPUs, 2 GB de RAM e 10 GB livres; 4 CPUs e 6 GB de RAM deixam o laboratório mais confortável.

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

O instalador é reconciliador: ao ser executado novamente, verifica cada etapa antes de alterá-la. Um cluster que já tenha `/etc/kubernetes/admin.conf` nunca é resetado automaticamente. O reparo com `kubeadm reset` é limitado a um bootstrap parcial sem `admin.conf`, após backup de `/etc/kubernetes`.

### Por que `NODE_IP` é fixo

O IPv4 NAT da distribuição WSL muda após encerramentos. A automação cria `10.254.254.1/32` na interface loopback por meio de systemd e usa esse endereço no kubelet e no API Server. Assim, `wsl.exe --shutdown`, reinícios do Windows e mudanças de VPN não invalidam o cluster.

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

## O que é instalado

- Kubernetes `v1.36` pelo repositório `pkgs.k8s.io`;
- `containerd` e `runc` do Ubuntu, com cgroups `systemd`;
- `kubeadm`, `kubelet`, `kubectl`, CNI plugins e `crictl`;
- Flannel `v0.28.8`, com manifesto validado por SHA-256;
- Headlamp `v0.45.0` com HTTPS no backend;
- serviço systemd para o IPv4 estável do nó;
- serviço systemd para o encaminhamento HTTPS em `127.0.0.1`.

Não são instalados ou configurados: UFW, OIDC, Keycloak, ingress controller, LoadBalancer, NodePort, Docker Desktop ou componentes no Windows.

## Configuração

| Variável | Padrão | Uso |
|---|---:|---|
| `KUBERNETES_MINOR` | `v1.36` | canal minor do repositório Kubernetes |
| `NODE_IP` | `10.254.254.1` | endereço estável interno criado em `lo` |
| `NODE_NAME` | `kubernetes-wsl` | nome fixo do nó |
| `ADMIN_USER` | usuário que chamou `sudo` | recebe `~/.kube/config` e a CA pública |
| `POD_NETWORK_CIDR` | `10.244.0.0/16` | rede Flannel |
| `SERVICE_CIDR` | `10.96.0.0/12` | rede dos Services |
| `DASHBOARD_LOCAL_PORT` | `30443` | porta local do Windows/WSL |
| `DASHBOARD_DEFAULT_LANGUAGE` | `pt` | idioma do link do Headlamp |
| `ALLOW_LOW_RESOURCES` | `false` | permite prosseguir abaixo dos mínimos |
| `AUTO_REPAIR_PARTIAL_CLUSTER` | `true` | repara somente bootstrap incompleto sem `admin.conf` |

## Operação diária

O cluster inicia quando a distribuição WSL é iniciada. Não é preciso executar o instalador novamente após reiniciar o Windows.

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n kubernetes-dashboard get deployment,pod,service
systemctl status containerd kubelet k8s-headlamp-local --no-pager
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

Logs relevantes:

```bash
sudo journalctl -u containerd -u kubelet -u k8s-headlamp-local -n 200 --no-pager
kubectl -n kubernetes-dashboard logs deployment/headlamp --tail=200
```

Consulte também [KUBERNETES_COMMANDS.md](KUBERNETES_COMMANDS.md).

## Ambiente corporativo

- VPN e proxy: o WSL atual pode herdar proxy e DNS do Windows. Se downloads falharem, valide `getent hosts pkgs.k8s.io` e `curl -I https://pkgs.k8s.io` antes de instalar.
- Proxy autenticado: prefira configuração corporativa de APT e variáveis de ambiente fornecidas pela TI; não versione credenciais em `cluster.env`.
- Política de execução: os scripts Windows são `.cmd`, não usam PowerShell e controlam o túnel por `wsl.exe`/systemd.
- Firewall: esta pasta não chama `ufw`, `netsh advfirewall` ou APIs do Windows Firewall.
- Exposição remota: deliberadamente não suportada enquanto o Headlamp estiver em login automático com `cluster-admin`.

## Diagnóstico

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
