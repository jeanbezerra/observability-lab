# Rancher em uma VM externa ao cluster

Instalação independente e genérica para Ubuntu Server 26.04 LTS. A pasta tem
o nome `ranher` conforme solicitado. O servidor Rancher roda em Docker com
dados persistentes; Nginx publica HTTPS e WebSocket. O backend Docker só escuta
em `127.0.0.1`, separado dos clusters Kubernetes que o Rancher administra.

O padrão é Rancher `v2.15.2`, com versão explícita e sem tag `latest`. Este
modo de nó único segue a instalação Docker oficial para laboratório/HML.
Para produção com alta disponibilidade, a instalação oficial usa Helm em um
cluster de gerenciamento dedicado; esta pasta não cria essa topologia.

## Instalar

Copie esta pasta para a VM, incluindo `scripts/lib`, e execute:

```bash
cd ranher
sudo bash install-all.sh
```

O instalador solicita o hostname DNS e o IPv4 da máquina e guarda a configuração
local em `rancher.env`, com permissão 600 e ignorada pelo Git. Não há domínio,
IP, usuário SSH ou certificado de empresa embutido no projeto. Para execução
sem interação:

```bash
cp .env.example rancher.env
# Preencha RANCHER_FQDN e SERVER_IP e revise o TLS.
sudo bash install-all.sh rancher.env
```

Antes de qualquer pacote, verifica/corrige `America/Sao_Paulo`, confirma
sincronização pelos pools NTP brasileiros e expande a raiz para aproveitar o
espaço elegível do disco/LVM. A imagem precisa conter Chrony ou timesyncd,
Python 3 e as ferramentas do seu layout de disco. Se não houver sincronização
ou a expansão não for segura, para antes da instalação. Exige 4 vCPUs, 8 GiB
de RAM e 20 GiB livres após expansão. Backups da expansão ficam em
`/var/lib/installer-host/backups`; logs têm offset de São Paulo e ficam em
`/var/log/rancher-bootstrap`.

O DNS precisa resolver o hostname para o IPv4 real da VM. DNS internos e
externos configurados no mesmo link devem compartilhar a visão desse nome;
um DNS público que retorna NXDOMAIN não serve como fallback para nome privado.
Não são criadas entradas permanentes em `/etc/hosts` nem CAs globais.

## TLS e agentes

`TLS_MODE=private-ca` cria uma CA local e um certificado com o hostname/IP da
instalação em `/opt/rancher/pki`. A chave CA é privada e não deve ser distribuída.
Somente `root-ca.crt` é fornecido a clientes/agentes. A CA é montada no Rancher
como `cacerts.pem`, somente leitura. O certificado do servidor é renovado se
o hostname mudar ou restar menos de uma semana de validade, preservando CA e
chave. PKI incompleta ou CA perto de expirar exige correção explícita.

Para um certificado já emitido, use `TLS_MODE=provided`, `TLS_CERT_FILE` (PEM
com leaf/intermediárias), `TLS_KEY_FILE` e, quando a CA for privada,
`TLS_CA_FILE` (cadeia CA PEM). Com CA pública confiável no Ubuntu, deixe
`TLS_CA_FILE` vazio: Rancher usa `--no-cacerts` e `agent-tls-mode=system-store`.
Com CA privada, usa `agent-tls-mode=strict`. Valida cadeia, hostname, validade
e correspondência entre certificado e chave; não ignora TLS.

A checagem final exige HTTP 200 e `pong` de `/ping`, verifica `/rancherversion`,
a CA publicada e `agent-tls-mode`. Conclua o primeiro acesso autenticado na
interface Rancher. O instalador não mostra bootstrap passwords ou tokens de
registro nos logs. O registro dos clusters fica no instalador Kubernetes HML.

Testes sem instalar componentes ou tocar em discos reais:

```bash
bash tests/tls.sh
bash tests/container.sh
bash tests/verify.sh
```

## Reexecutar

Reutiliza a PKI e o container existentes quando imagem, persistência, CA,
privilégios, restart policy e publicação loopback correspondem à configuração.
Diferenças param a instalação: o container nunca é removido/recriado para
resolver drift. Não faz upgrades nem restaura revisões Helm automaticamente.
Certificados, metadados e configuração Nginx têm backup quando alterados.
As etapas têm `--check` e o instalador completo reconcilia apenas o que não
estiver conforme, verificando novamente após cada alteração.

`ENABLE_UFW=false` preserva um firewall inativo. Um UFW já ativo recebe regras
TCP/80 e TCP/443; ao ativá-lo explicitamente, libera `SSH_PORT` antes. NTP usa
UDP/123 de saída. Faça backup dos dados em `/opt/rancher/data` e da PKI com o
procedimento Rancher antes de qualquer upgrade.

Referências: [Docker com TLS externo Nginx](https://ranchermanager.docs.rancher.com/v2.13/how-to-guides/advanced-user-guides/configure-layer-7-nginx-load-balancer),
[arquitetura de gerenciamento](https://ranchermanager.docs.rancher.com/reference-guides/rancher-manager-architecture/architecture-recommendations),
[Docker Engine Ubuntu](https://docs.docker.com/engine/install/ubuntu/),
[NTP brasileiro](https://www.ntppool.org/en/zone/br).
