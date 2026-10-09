# Kubernetes HML — VM Ubuntu 26.04 LTS e Rancher externo

Variante independente de `kubernetes-wsl`, para uma VM Ubuntu Server **26.04 LTS** com systemd e acesso pela rede HML. Mantém kubeadm, containerd, Flannel, CoreDNS, Helm, Headlamp, Gateway API e Envoy Gateway. O servidor Rancher fica em outra máquina; esta pasta instala o cluster e seus agentes de registro.

| Componente | Referência |
| --- | --- |
| Kubernetes | 1.36, pacotes kubeadm/kubelet/kubectl/crictl |
| Runtime | containerd do Ubuntu, cgroup systemd |
| Rede | Flannel 0.28.8 e CoreDNS do kubeadm |
| Helm | 4.3.0 |
| Gateway API / Envoy Gateway | 1.6.1 Standard / 1.9.1 |
| Headlamp | 0.45.0, HTTPS, ServiceAccount administrativa |
| Rancher externo | 2.15.2 como referência de compatibilidade |

A [matriz do Rancher 2.15.2](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/rancher-v2-15-2/) certifica a importação de clusters genéricos Kubernetes 1.34–1.36. Confira a versão real do seu servidor em **About** e ajuste `RANCHER_VERSION`. No [registro Generic](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup/register-existing-clusters), Rancher administra workloads, projetos e RBAC. Nesta variante kubeadm, manutenção dos nós, upgrades Kubernetes e backup do etcd são feitos na VM.

```text
Máquina externa: Rancher HTTPS
             ^
             | HTTPS de saída (agentes do cluster)
             |
VM Ubuntu 26.04 LTS — HML, nó único
  kubeadm / containerd / Flannel / CoreDNS
  Headlamp HTTPS NodePort 30443 <── navegador na rede HML
  Envoy HTTP NodePort 30080     <── aplicações HTTP/gRPC
  API Kubernetes TLS 6443      <── kubectl autorizado
```

## Instalar na VM

Use uma VM dedicada, com IPv4 acessível pela rede HML. Mínimo: **2 CPUs, 4 GB RAM e 20 GiB livres**; recomendado: **4 CPUs, 8 GB RAM e 40 GB de disco**. A rede da VM deve permitir comunicação com as máquinas clientes e com o Rancher. O instalador não altera netplan, DHCP, firewall ou regras do hipervisor.

Copie esta pasta para a VM, entre nela e execute a partir do usuário Linux que receberá o kubeconfig:

```bash
cd ~/observability-lab/kubernetes-hml
sudo bash install-all.sh
```

O instalador cria `cluster.env` e solicita o **IPv4 atual da VM** e a **URL HTTPS do Rancher externo**. O IP sugerido vem da rota padrão; informe o endereço realmente alcançável. Os valores são guardados no arquivo local, com modo `0600`, e reutilizados nas próximas execuções. Não há valores de IP ou URL fixados no código.

Para preparar configuração antes da instalação ou usar um nome DNS para o Headlamp:

```bash
cp .env.example cluster.env
nano cluster.env
sudo bash install-all.sh cluster.env
```

Preencha `NODE_IP`, `RANCHER_URL` e, opcionalmente, `HEADLAMP_HOST` com um nome DNS apontado para a VM. `HEADLAMP_HOST` vazio usa o IP. O instalador descobre os resolvedores e a versão do Rancher e trata a confiança TLS conforme esse endpoint. Para uma CA privada nova, confirme seu fingerprint na instalação ou forneça uma CA confiável em `RANCHER_CA_FILE`.

Os parâmetros são definidos no momento da instalação. **Depois do bootstrap**, `NODE_IP`, `NODE_NAME` e as redes de Pods/Services precisam permanecer estáveis. Use reserva DHCP quando o IP vier de DHCP. Uma troca posterior do IP exige planejar a migração de certificados, kubeconfigs e identidade do nó; reexecutar o instalador não faz essa migração.

O perfil é de nó único, com workloads no control plane. `SINGLE_NODE=false` é recusado: expansão para múltiplos nós exige outro fluxo de provisionamento. Um cluster já existente sem o marcador desta variante é recusado antes de alterações. A reinstalação reconcilia componentes e preserva um control plane já inicializado. O reparo automático com reset se limita a um bootstrap parcial desta variante, sem `admin.conf`, com API indisponível e backup prévio.

## Acessar o Headlamp sem senha

Depois da instalação:

```text
https://IP_DA_VM:30443/?lng=pt
```

Com `HEADLAMP_HOST` configurado, use esse nome na URL. O Headlamp usa seu token interno de ServiceAccount automaticamente: não solicita senha, OIDC ou token manual. O [modo usado pelo Headlamp](https://raw.githubusercontent.com/kubernetes-sigs/headlamp/v0.45.0/backend/pkg/config/config.go) dá **cluster-admin a todo cliente que alcança a interface**. Restrinja a porta à rede HML autorizada. A autenticação do próprio servidor Rancher continua sendo a configurada nele.

O TLS é emitido por uma CA local, incluindo o IP da VM e o nome configurado. Copie **somente** `~/.kube/headlamp-ca.crt` para as máquinas clientes e importe no repositório de certificados confiáveis do sistema/navegador. No Ubuntu cliente:

```bash
sudo install -m 0644 headlamp-ca.crt /usr/local/share/ca-certificates/headlamp-hml.crt
sudo update-ca-certificates
```

No Windows cliente, após copiar o certificado, no CMD do usuário:

```bat
certutil.exe -user -addstore Root headlamp-ca.crt
```

As chaves privadas ficam na VM em `/etc/kubernetes/pki/headlamp`, com modo `0600`. Confiar nessa CA evita o aviso de certificado no navegador; ela é diferente da CA do Rancher.

## Registrar no Rancher externo

1. No Rancher, abra **Cluster Management → Import Existing → Generic**, dê um nome ao cluster HML e crie o registro.
2. Salve o **manifesto YAML de registro** gerado para esse cluster fora do repositório, por exemplo `/home/SEU_USUARIO/rancher-import.yaml`. Ele contém credenciais; mantenha modo `0600`.
3. Configure `RANCHER_IMPORT_MANIFEST` com o caminho absoluto no `cluster.env` e execute:

```bash
sudo env K8S_CONFIG_FILE="$PWD/cluster.env" bash scripts/80-register-rancher.sh
```

Também pode reexecutar `sudo bash install-all.sh cluster.env`. O script confere TLS de `/ping`, o destino `CATTLE_SERVER` e os agentes. Confirme o estado **Active** na interface do Rancher. Sem o manifesto, o cluster e seus acessos são instalados e o registro é apresentado como **PENDENTE**. Não há credencial de importação de exemplo.

Para detalhes de CA pública/privada e confiança dos agentes, veja [rancher/README.md](rancher/README.md). A VM e os Pods precisam resolver e alcançar a URL do Rancher; um teste de `/ping` no host não prova o caminho de rede dos Pods.

O fluxo é genérico: DNS automático usa os resolvedores reais da VM, a versão
Rancher é descoberta por HTTPS e as CAs aprovadas ficam fora do Git, vinculadas
à URL da instalação. Não há domínios, IPs ou certificados de empresa no
projeto. Veja [reconciliação DNS/TLS e diagnóstico](rancher/README.md).

## Rede e aplicações HML

| Origem → destino | Porta | Uso |
| --- | --- | --- |
| Clientes autorizados → VM | TCP 30443 | Headlamp HTTPS sem senha |
| Clientes → VM | TCP 30080 | HTTP e gRPC via Envoy |
| Clientes de administração → VM | TCP 6443 | Kubernetes API com autenticação |
| VM/Pods → Rancher externo | TCP 443 ou porta da URL | Registro e administração |
| VM → repositórios/registries | TCP 443 | Pacotes, charts e imagens |

As portas NodePort podem ser alteradas em `cluster.env`, dentro de `30000–32767`. A aplicação precisa de um `HTTPRoute`/`GRPCRoute` associado ao Gateway `gateway-system/hml-gateway`. Veja [os exemplos](manifests/gateway/examples/README.md). Sem uma rota para a requisição, a porta 30080 pode responder **404**, indicando que o Envoy respondeu.

Se houver UFW, firewall externo ou NAT, configure as permissões para as redes corretas. NodePort é implementado pelo kube-proxy e pode não aparecer como processo em `ss`; o diagnóstico testa Services e requisições reais. O Flannel padrão não implementa [NetworkPolicy](https://github.com/flannel-io/flannel/blob/master/Documentation/netpol.md); esta variante não fornece isolamento de rede entre projetos Rancher.

## Operação e cache offline

```bash
kubectl get nodes -o wide
kubectl get pods -A
sudo bash diagnose.sh cluster.env
sudo bash diagnose.sh --repair-dry-run cluster.env
sudo bash diagnose.sh --repair cluster.env
sudo env K8S_CONFIG_FILE="$PWD/cluster.env" bash scripts/90-verify.sh
```

Os logs ficam em `/var/log/k8s-hml-bootstrap`, com modo `0600`; o diagnóstico é somente leitura por padrão. A recuperação é limitada a três ações e cinco minutos, sem reset de cluster ou exclusão de dados. O swap do host permanece disponível, enquanto os Pods usam `NoSwap`.

O cache conserva os modos `auto`, `online`, `offline` e `cache`. Para baixar o bundle já publicado:

```bash
bash setup-offline-cache.sh
sudo bash install-all.sh cluster.env
```

O bundle existente da variante WSL usa o mesmo Ubuntu e versões, mas pode não incluir `python3`. No modo offline, deixe `python3` previamente instalado ou gere um bundle HML com o [builder](offline-bundle-builder/HELP.md), que inclui esse pacote. Imagens de contêiner e a conexão Rancher continuam exigindo acesso a seus servidores.

Veja [comandos operacionais](KUBERNETES_COMMANDS.md) e [desligamento gracioso](GRACEFUL_NODE_SHUTDOWN.md). Esta pasta não instala workloads que não existam em `kubernetes-wsl` e não fornece alta disponibilidade ou provisionador de armazenamento persistente.

Os testes de configuração, NodePort e importação Rancher podem ser executados
sem cluster ou rede; veja [tests/README.md](tests/README.md). A validação em uma
VM real e o teste a partir de uma máquina cliente precisam ocorrer no ambiente
HML com seus parâmetros de rede.

## Remover

```bash
sudo bash uninstall-all.sh --help
sudo bash uninstall-all.sh --dry-run cluster.env
```

Confira as opções de remoção na ajuda antes de usar o modo efetivo. Remover o cluster local não exclui seu registro do servidor Rancher externo.

## Hor?rio e disco antes da instala??o

Antes de instalar/reconciliar qualquer componente, o instalador configura
`America/Sao_Paulo`, usa os pools NTP brasileiros `0.br.pool.ntp.org` a
`3.br.pool.ntp.org` e exige sincroniza??o confirmada. Os timestamps dos logs
incluem o offset de S?o Paulo. A imagem Ubuntu precisa ter Python 3, util-linux
e Chrony ou systemd-timesyncd previamente dispon?veis; o instalador n?o instala
pacotes para contornar uma falha de rel?gio.

`HOST_DISK_AUTO_EXPAND=true` expande automaticamente a raiz em layout simples:
?ltima parti??o raiz/PV, PV, todo o espa?o livre do VG e filesystem ext4/XFS.
Cria backups de tabela/metadados em `/var/lib/installer-host/backups`. N?o move
outras parti??es nem toma espa?o de outros LVs. Layouts amb?guos, criptografados,
RAID, multi-PV ou thin/snapshot exigem corre??o manual antes de continuar.
Aproveitar o disco significa alocar sua capacidade, n?o preench?-lo com dados;
os limites de espa?o livre para instalar continuam sendo verificados depois.
`--check` apenas verifica; `HOST_DISK_AUTO_EXPAND=false` bloqueia quando houver
capacidade n?o alocada. Ferramentas de expans?o necess?rias devem estar na imagem.
