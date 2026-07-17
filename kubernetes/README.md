# Kubernetes com Dashboard remoto no Ubuntu 26.04 LTS

Este diretório instala, com um único comando, um cluster Kubernetes de nó único no Ubuntu Server 26.04 LTS. A automação prepara o sistema operacional, instala `containerd`, `kubeadm`, `kubelet` e `kubectl`, inicializa o control plane, instala a rede Flannel e publica um Dashboard HTTPS permanente na porta TCP `30443`.

> **Importante:** o projeto chamado **Kubernetes Dashboard** foi arquivado e está sem manutenção desde 2026. A própria documentação do Kubernetes recomenda o **Headlamp** para novas instalações. Por isso, este projeto usa o Headlamp como Dashboard Web, com login por token e autorização via RBAC. Consulte a [documentação oficial do Kubernetes](https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/) e o [projeto Headlamp](https://headlamp.dev/).

## O que é instalado

- Kubernetes `v1.36` pelo repositório oficial `pkgs.k8s.io`;
- `containerd` fornecido pelo Ubuntu 26.04, configurado com cgroups `systemd`;
- Flannel `v0.28.4` como CNI, com download validado por SHA-256;
- Headlamp `v0.43.0`, executado como `Deployment` e reiniciado automaticamente;
- serviço `NodePort` HTTPS fixo em `30443`;
- certificado e autoridade certificadora locais, gerados automaticamente;
- usuário Linux operacional e kubeconfig protegido;
- identidades Kubernetes `dashboard-viewer` e, opcionalmente, `dashboard-admin`;
- UFW com SSH preservado e acesso remoto ao Dashboard;
- utilitário `/usr/local/sbin/k8s-dashboard-token` para tokens temporários;
- validação final do nó, CNI, DNS, RBAC, TLS e endpoint HTTPS do nó.

O resultado é um cluster de **nó único**, apropriado para laboratório, desenvolvimento, edge e pequenas instalações. Ele não é de alta disponibilidade: uma falha nessa máquina interrompe o control plane e os workloads.

## Arquitetura

```text
máquina externa
     |
     | HTTPS TCP/30443
     v
firewall/NAT/security group
     |
     v
Ubuntu 26.04 ── NodePort 30443 ── Headlamp Pod
     |                                  |
     | containerd + kubelet             | token temporário
     v                                  v
control plane Kubernetes <──────────── RBAC
```

O Dashboard é persistente porque o Kubernetes mantém o Pod do Headlamp em execução e `containerd`/`kubelet` são habilitados no boot pelo systemd. Não há um `kubectl port-forward` que precise permanecer aberto.

## Pré-requisitos

- Ubuntu **Server 26.04 LTS** instalado diretamente, em VM ou em instância cloud;
- acesso `root` via `sudo`;
- 2 CPUs, 2 GB de RAM e 10 GB livres no mínimo; recomenda-se 4 GB de RAM e 20 GB livres;
- hostname único e conexão com a Internet;
- IPv4 fixo ou reservado para o servidor;
- para Internet residencial: acesso ao roteador para criar encaminhamento de porta;
- para cloud: permissão para alterar o firewall ou security group da instância.

Portas relevantes:

| Porta | Origem | Finalidade |
|---|---|---|
| TCP `22` | rede administrativa | SSH; altere `SSH_PORT` se necessário |
| TCP `30443` | `DASHBOARD_ALLOWED_CIDR` | Dashboard HTTPS remoto |
| TCP `6443` | local/control plane | API Kubernetes; não é aberta publicamente por estes scripts |

O encaminhamento no roteador e regras de security group pertencem à infraestrutura externa ao Ubuntu e, portanto, não podem ser descobertos ou alterados com segurança pelo instalador.

## Instalação rápida

Entre na pasta no servidor Ubuntu:

```bash
cd kubernetes
cp .env.example cluster.env
chmod 600 cluster.env
nano cluster.env
```

Para acesso remoto, revise pelo menos estas variáveis:

```bash
# IPv4 privado/fixo da interface do servidor. Vazio = detecção automática.
NODE_IP="192.168.1.50"

# Informe um deles para incluí-lo no certificado HTTPS.
DASHBOARD_PUBLIC_IP="203.0.113.10"
DASHBOARD_DNS_NAME="k8s.exemplo.com"

# 0.0.0.0/0 permite qualquer IPv4 externo.
DASHBOARD_ALLOWED_CIDR="0.0.0.0/0"
DASHBOARD_NODE_PORT="30443"

# Porta real usada pelo sshd antes de o UFW ser ativado.
SSH_PORT="22"
```

Execute toda a instalação:

```bash
sudo bash install-all.sh cluster.env
```

Os scripts são idempotentes para o fluxo normal: podem ser executados novamente para concluir uma instalação interrompida ou reaplicar configurações. O instalador não executa `kubeadm reset`, não apaga workloads e não recria um cluster já inicializado.

## Liberar acesso fora da rede do servidor

O script publica o serviço em todas as interfaces Kubernetes do nó e abre o UFW. Para que uma máquina realmente externa chegue ao servidor, configure também a borda da rede.

### Servidor atrás de roteador/NAT

1. Reserve o `NODE_IP` no DHCP ou configure um IPv4 privado fixo.
2. No roteador, encaminhe **TCP `30443` externo** para **`NODE_IP:30443`**.
3. Se utilizar DNS, aponte `DASHBOARD_DNS_NAME` para o IPv4 público.
4. Caso o provedor use CGNAT, solicite um IPv4 público ou use uma VPN; redirecionamento de porta não funciona através de CGNAT sem suporte do provedor.

### Instância em nuvem

1. Associe um IPv4 público ou Load Balancer à instância.
2. No security group/firewall do provedor, permita TCP `30443` a partir do CIDR desejado.
3. Mantenha a regra do UFW com o mesmo CIDR.
4. Não publique TCP `6443` sem um projeto específico de segurança da API.

### Teste externo

Em uma máquina fora da rede, depois de copiar a CA conforme a próxima seção:

```bash
curl --cacert headlamp-ca.crt https://k8s.exemplo.com:30443/
```

No navegador, acesse:

```text
https://k8s.exemplo.com:30443
```

ou:

```text
https://IP_PUBLICO:30443
```

O IP ou nome usado no navegador precisa ter sido configurado em `DASHBOARD_PUBLIC_IP` ou `DASHBOARD_DNS_NAME` **antes** da instalação. Se mudar depois, atualize `cluster.env` e reexecute `scripts/60-install-dashboard.sh`.

## Confiar no certificado HTTPS

A chave privada permanece exclusivamente no servidor, em `/etc/kubernetes/pki/headlamp/tls.key`. A CA pública é copiada para `~/.kube/headlamp-ca.crt` do `ADMIN_USER` e pode ser distribuída às máquinas clientes.

Copie a CA para o cliente:

```bash
scp usuario@servidor:~/.kube/headlamp-ca.crt .
```

Ubuntu/Debian cliente:

```bash
sudo cp headlamp-ca.crt /usr/local/share/ca-certificates/k8s-dashboard.crt
sudo update-ca-certificates
```

Windows, em PowerShell executado como Administrador:

```powershell
certutil -addstore -f Root .\headlamp-ca.crt
```

macOS:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain headlamp-ca.crt
```

Reabra o navegador depois da importação. Não copie `ca.key` nem `tls.key` para clientes.

## Login e usuários

O Headlamp pede um Bearer Token. Gere tokens somente quando for usar o Dashboard; eles não ficam gravados em arquivos.

Perfil recomendado, somente leitura:

```bash
sudo k8s-dashboard-token viewer 8h
```

Perfil administrativo, com acesso total ao cluster:

```bash
sudo k8s-dashboard-token admin 1h
```

Copie a saída e cole no campo de token do Headlamp. A duração aceita segundos, minutos ou horas, por exemplo `900s`, `30m` e `8h`. O API Server pode reduzir uma duração acima do limite configurado no cluster.

| Identidade | Tipo | Permissões |
|---|---|---|
| `ADMIN_USER` | usuário Linux | possui `~/.kube/config` com modo `0600` para administração via `kubectl` |
| `k8s-operators` | grupo Linux | pode executar o emissor de token instalado com modo `0750` |
| `headlamp` | ServiceAccount | executa a UI; não recebe ClusterRole administrativo |
| `dashboard-viewer` | ServiceAccount | visualiza workloads e objetos do cluster, sem ler Secrets |
| `dashboard-admin` | ServiceAccount | recebe `cluster-admin`; habilitado por padrão e deve ser usado com cautela |

Para não criar a identidade administrativa, configure antes da instalação:

```bash
CREATE_ADMIN_SERVICE_ACCOUNT="false"
```

O Kubernetes não cria “usuários com senha” internamente. As identidades do Dashboard são ServiceAccounts autenticadas por tokens temporários e autorizadas por RBAC, que é o mecanismo nativo para este cenário.

## Segurança do acesso público

`DASHBOARD_ALLOWED_CIDR="0.0.0.0/0"` atende ao requisito de acesso por qualquer máquina IPv4, mas expõe a tela de login à Internet. A comunicação continua criptografada e nenhuma ação é autorizada sem token válido, porém a opção mais segura é restringir a origem:

```bash
# Um único IP público
DASHBOARD_ALLOWED_CIDR="198.51.100.27/32"

# Uma rede corporativa
DASHBOARD_ALLOWED_CIDR="198.51.100.0/24"
```

Para uso permanente em produção, prefira acesso por VPN (WireGuard, Tailscale ou VPN corporativa), autenticação OIDC e certificado emitido por uma CA pública. Nunca compartilhe um token `admin`; emita um token curto para cada sessão.

O UFW do host não substitui o firewall do provedor ou do roteador. Mantenha a mesma restrição de origem nas duas camadas. O Flannel fornece conectividade CNI, mas não aplica NetworkPolicies; se políticas de rede forem requisito, substitua-o por um CNI que as implemente.

## Configuração

As opções estão documentadas em `.env.example`:

| Variável | Padrão | Descrição |
|---|---|---|
| `KUBERNETES_MINOR` | `v1.36` | canal menor do repositório oficial Kubernetes |
| `NODE_IP` | automático | IPv4 privado/fixo anunciado pelo control plane |
| `NODE_NAME` | hostname | nome do nó Kubernetes |
| `ADMIN_USER` | `SUDO_USER` ou `k8sadmin` | usuário Linux que recebe o kubeconfig |
| `SINGLE_NODE` | `true` | remove o taint do control plane para permitir workloads |
| `POD_NETWORK_CIDR` | `10.244.0.0/16` | rede dos Pods/Flannel |
| `SERVICE_CIDR` | `10.96.0.0/12` | rede virtual dos Services |
| `DASHBOARD_NODE_PORT` | `30443` | porta HTTPS, dentro do intervalo NodePort |
| `DASHBOARD_ALLOWED_CIDR` | `0.0.0.0/0` | origem IPv4 aceita pelo UFW |
| `DASHBOARD_DNS_NAME` | vazio | DNS incluído no SAN do certificado |
| `DASHBOARD_PUBLIC_IP` | vazio | IPv4 público incluído no SAN do certificado |
| `DASHBOARD_CERT_DAYS` | `825` | validade do certificado do servidor |
| `DASHBOARD_ROLLOUT_TIMEOUT` | `10m` | tempo máximo para baixar/iniciar o Headlamp |
| `CREATE_ADMIN_SERVICE_ACCOUNT` | `true` | cria a identidade administrativa do Dashboard |
| `DEFAULT_TOKEN_DURATION` | `8h` | duração padrão de um token novo |
| `ENABLE_UFW` | `true` | configura e ativa UFW |
| `SSH_PORT` | `22` | porta liberada antes da ativação do UFW |

`cluster.env` é carregado como configuração Bash e deve ser editado somente por administradores. Ele está ignorado por `.gitignore` e deve permanecer com modo `0600`.

## Scripts segmentados

| Ordem | Script | Responsabilidade |
|---|---|---|
| 00 | `00-preflight.sh` | valida Ubuntu, hardware, rede, nomes, portas e variáveis |
| 10 | `10-prepare-host.sh` | instala utilitários, cria usuário/grupo, desativa swap e configura kernel |
| 20 | `20-install-containerd.sh` | instala/configura containerd 2.x com cgroup systemd |
| 30 | `30-install-kubernetes.sh` | configura o APT oficial e instala kubelet/kubeadm/kubectl |
| 40 | `40-bootstrap-cluster.sh` | executa `kubeadm init`, instala kubeconfig e configura nó único |
| 50 | `50-install-network.sh` | valida e aplica o manifesto Flannel |
| 60 | `60-install-dashboard.sh` | emite TLS, instala Headlamp e cria o NodePort persistente |
| 70 | `70-configure-firewall.sh` | preserva SSH, libera CNI e abre a porta do Dashboard no UFW |
| 80 | `80-create-users.sh` | aplica RBAC e instala o emissor de tokens |
| 90 | `90-verify.sh` | testa systemd, nó, CNI, DNS, RBAC e HTTPS |

Para reexecutar apenas uma etapa usando a configuração:

```bash
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/60-install-dashboard.sh
```

## Permissões e arquivos gerados

| Caminho | Permissão | Conteúdo |
|---|---|---|
| `/etc/kubernetes/admin.conf` | root, protegido pelo kubeadm | kubeconfig administrativo original |
| `~ADMIN_USER/.kube/config` | `0600` | cópia administrativa para `kubectl` |
| `/etc/kubernetes/pki/headlamp/ca.key` | `0600` | chave privada da CA; não deve sair do servidor |
| `/etc/kubernetes/pki/headlamp/tls.key` | `0600` | chave privada HTTPS do Headlamp |
| `~ADMIN_USER/.kube/headlamp-ca.crt` | `0644` | certificado público da CA para os clientes |
| `/var/lib/k8s-bootstrap/kubeadm-init.log` | `0600` | saída inicial do kubeadm, potencialmente sensível |
| `/usr/local/sbin/k8s-dashboard-token` | `0750`, grupo operador | emissor de tokens temporários |

`install-all.sh` também normaliza os scripts para `0750` e os manifests para `0640`, inclusive quando a pasta foi copiada de Windows ou extraída de ZIP.

## Operação diária

Estado geral:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl -n kubernetes-dashboard get deployment,pod,service
```

Logs do Dashboard:

```bash
kubectl -n kubernetes-dashboard logs deployment/headlamp --tail=200
```

Serviços do host:

```bash
sudo systemctl status containerd kubelet
sudo journalctl -u containerd -u kubelet --since today
```

Firewall:

```bash
sudo ufw status numbered
```

Verificação completa:

```bash
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/90-verify.sh
```

Após reiniciar o servidor, aguarde de um a três minutos e confirme que o nó voltou a `Ready`. Não é necessário iniciar o Dashboard manualmente.

## Solução de problemas

### O navegador não conecta

1. Rode `sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" bash scripts/90-verify.sh` no servidor.
2. Confira `sudo ufw status` e `kubectl -n kubernetes-dashboard get svc headlamp`.
3. Teste localmente: `curl --cacert /etc/kubernetes/pki/headlamp/ca.crt https://NODE_IP:30443/`.
4. Teste TCP externamente: `nc -vz IP_PUBLICO 30443`.
5. Revise NAT, CGNAT, security group e firewall do provedor.

### Erro de certificado

Confirme que o endereço usado está no certificado:

```bash
openssl x509 -in /etc/kubernetes/pki/headlamp/tls.crt \
  -noout -subject -ext subjectAltName
```

Se não estiver, ajuste `DASHBOARD_PUBLIC_IP`/`DASHBOARD_DNS_NAME` e reexecute a etapa 60 com `K8S_CONFIG_FILE`, conforme mostrado na seção "Scripts segmentados".

### Token rejeitado

Gere outro token e confira o relógio do servidor:

```bash
timedatectl status
sudo k8s-dashboard-token viewer 1h
```

### `old replicas are pending termination` ou timeout do Headlamp

A etapa 60 usa estratégia `Recreate`, pré-baixa a imagem no containerd e imprime automaticamente Pods, eventos e logs se o Headlamp não ficar pronto. Reexecute somente essa etapa:

```bash
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/60-install-dashboard.sh
```

`kubeadm config images pull` não baixa o Headlamp; esse comando cobre apenas as imagens do control plane. Para testar o Dashboard diretamente:

```bash
sudo crictl --runtime-endpoint=unix:///run/containerd/containerd.sock \
  pull ghcr.io/headlamp-k8s/headlamp:v0.43.0
```

Se uma versão antiga do Deployment continuar presa em `Terminating`, remova somente o Deployment do Dashboard e reexecute a etapa 60. O cluster e os demais workloads não são afetados:

```bash
kubectl -n kubernetes-dashboard delete deployment headlamp
sudo env K8S_CONFIG_FILE="$(realpath cluster.env)" \
  bash scripts/60-install-dashboard.sh
```

### Nó `NotReady`

```bash
sudo systemctl status containerd kubelet
sudo journalctl -u kubelet -n 200 --no-pager
kubectl -n kube-flannel get pods -o wide
```

Verifique também se swap permaneceu desativada com `swapon --show` e se `br_netfilter` está carregado com `lsmod | grep br_netfilter`.

## Referências oficiais

- [Ubuntu 26.04 LTS release notes](https://documentation.ubuntu.com/release-notes/26.04/)
- [Instalação do kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Container runtimes e cgroups systemd](https://kubernetes.io/docs/setup/production-environment/container-runtimes/)
- [Criação de cluster com kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Flannel](https://github.com/flannel-io/flannel)
- [Headlamp in-cluster](https://headlamp.dev/docs/latest/installation/in-cluster/)
- [Autenticação do Headlamp](https://headlamp.dev/docs/latest/installation/)
