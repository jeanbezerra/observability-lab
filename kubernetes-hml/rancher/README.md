# Registrar HML em um Rancher externo

Esta variante instala Kubernetes com kubeadm e registra um cluster **Generic**
em um Rancher existente. URL, IP da VM, DNS e certificados pertencem à
configuração local de cada instalação. Não há perfil de empresa nem CA de
ambiente distribuída com o projeto.

O Rancher administra workloads, projetos e RBAC. Upgrades Kubernetes, nós e
backups do etcd continuam sob responsabilidade do kubeadm. A matriz de
referência Rancher **v2.15.2** certifica importação Kubernetes **1.34–1.36**;
confira a matriz da release descoberta antes de usar outra combinação.

## Configuração e reconciliação automáticas

O instalador solicita o IPv4 real da VM e a URL HTTPS do Rancher quando faltam
em `cluster.env`. Os demais padrões são genéricos:

| Parâmetro | Padrão | Comportamento |
| --- | --- | --- |
| `RANCHER_URL` | Coletado na instalação | Endpoint externo HTTPS, sem credenciais ou caminhos |
| `RANCHER_VERSION` | `auto` | Descobre a versão pelo endpoint HTTPS e verifica o manifesto |
| `RANCHER_DNS_MODE` | `auto` | Descobre e testa os resolvedores da VM |
| `RANCHER_DNS_SERVERS` | Vazio | Permite indicar resolvedores específicos da instalação |
| `RANCHER_CA_AUTO_DISCOVER` | `true` | Descobre a CA publicada pelo Rancher se faltar confiança |
| `RANCHER_CA_FILE` | Vazio | Permite fornecer uma cadeia CA confiável em PEM |
| `RANCHER_CA_FINGERPRINT` | Vazio | Confirma a identidade da CA em execução não interativa |
| `RANCHER_IMPORT_MANIFEST` | Vazio | Caminho do YAML Generic; vazio deixa o registro pendente |

### DNS

No modo automático, a etapa 79 consulta os resolvedores reais do host, sem usar
o stub de loopback do systemd como servidor dos Pods. Testa cada resolvedor para
o hostname do Rancher e seleciona os que correspondem à resolução do host.
Isso evita encaminhar um nome interno a um DNS público que retorna NXDOMAIN.

Os DNS configurados na mesma interface da VM devem apresentar a mesma visão
do hostname Rancher. Um DNS público que retorna NXDOMAIN não funciona como
fallback para um nome interno: o resolvedor do host pode escolhê-lo e falhar
de forma intermitente, mesmo com os agentes funcionando nos Pods. Configure
DNS internos recursivos que resolvam os nomes internos e externos, ou split
DNS explícito para o domínio correspondente. A reconciliação do CoreDNS não
altera o DNS do host; se o próprio host não resolver o Rancher, corrija essa
configuração antes de reexecutar o instalador.

O CoreDNS recebe um bloco identificado apenas para o hostname configurado. O
endereço do Rancher continua sendo obtido pelo DNS; as demais zonas e dados do
ConfigMap são preservados. A reexecução redescobre o ambiente e reconcilia
mudanças. O modo `off` preserva o DNS existente; uma lista explícita de
`RANCHER_DNS_SERVERS` permite substituir a descoberta.

Antes de alterar o Corefile, a etapa cria um backup privado. Só reinicia o
Deployment se o Corefile mudar, aguarda sua disponibilidade e grava o estado
após o sucesso. Blocos personalizados conflitantes não são sobrescritos.

### Certificados

Certificados emitidos por CAs já confiáveis no sistema funcionam diretamente.
Quando a confiança falta, a etapa consulta a CA pública publicada pelo Rancher,
valida o formato, a capacidade de assinar certificados e a validade, e testa
a cadeia e o hostname com essa CA.

Essa descoberta não comprova a identidade da CA. Na primeira utilização de uma
CA privada, confirme o fingerprint mostrado com o administrador do servidor.
A instalação interativa pede essa confirmação; sem terminal, forneça
`RANCHER_CA_FILE` confiável ou `RANCHER_CA_FINGERPRINT` previamente conferido.
Uma rotação de CA exige uma nova confirmação.
O fingerprint é SHA-256 do certificado DER para uma CA; em uma cadeia com
várias CAs, é SHA-256 dos DER concatenados na ordem publicada.

A CA aprovada fica em `BOOTSTRAP_STATE_DIR`, fora do Git, associada à URL da
instalação. Os testes finais de `/ping` sempre validam TLS e exigem **200/pong**.
Certificado expirado, hostname incorreto, redirects e resposta inesperada
interrompem o registro com diagnóstico. O script não altera a PKI do servidor
nem instala confiança global no sistema.

A confiança dos agentes nos containers depende de `cacerts` e
`agent-tls-mode` no servidor Rancher, separadamente da confiança do host.
Com CA privada, configure `strict` e a cadeia CA em `cacerts`. Com CA pública,
use `system-store` ou publique a CA para usar `strict`. Considere os clusters
existentes antes de alterar uma configuração global do Rancher.

## Importar o cluster

1. No Rancher, abra **Cluster Management > Import Existing > Generic** e crie o registro HML.
2. Salve o YAML da URL de importação em um arquivo local protegido na VM, fora do Git. Valide HTTPS ao baixar e aplique `chmod 600`.
3. Informe o caminho absoluto em `RANCHER_IMPORT_MANIFEST` no `cluster.env`.
4. Execute a etapa de registro ou reexecute o instalador:

```bash
sudo env K8S_CONFIG_FILE="$PWD/cluster.env" bash scripts/80-register-rancher.sh
# Ou:
sudo bash install-all.sh cluster.env
```

Para um registro já criado, abra sua página de **Registration** e use a URL
`/v3/import/...yaml` do comando exibido. **Export YAML** baixa o objeto `Cluster`
do servidor Rancher, que não registra os agentes no Kubernetes. Endereços
`blob:` pertencem à sessão do navegador e não são URLs de importação.

Se a aba **Registration** não aparecer, consulte a API no navegador autenticado:
`https://<rancher>/v3/clusterregistrationtokens?clusterId=<id-do-cluster>`.
Use a URL de importação do campo `command` ou `insecureCommand`, baixando o YAML
com validação da CA. O ID está no objeto `Cluster` exportado ou na URL da página
do cluster. Esse acesso recupera o registro existente.

O YAML e a URL de importação contêm credenciais. A etapa valida namespace,
workloads, imagem e `CATTLE_SERVER` antes de aplicar; registra somente o hash
do arquivo e não redireciona um agente existente para outro Rancher.

Quando o agente existe e o hash do manifesto já foi validado, a reexecução
preserva os recursos reconciliados pelo Rancher e verifica o destino e o rollout.
Isso mantém as credenciais, os volumes e as atualizações posteriores do agente.

Sem manifesto e sem agente, o instalador testa o endpoint e apresenta
**PENDENTE**. Um rollout pronto não comprova conexão upstream: confirme
**Active** no servidor Rancher.

## Diagnóstico

Teste somente leitura, sem kubeconfig. Use sudo se a CA autorizada estiver
no estado protegido do instalador root:

```bash
K8S_CONFIG_FILE="$PWD/cluster.env" bash test-rancher.sh
# Também aceita URL e uma CA local opcional:
bash test-rancher.sh https://rancher.example.org /caminho/ca-confiavel.crt
```

A opção `--configure-ca` habilita explicitamente a descoberta e a gravação da
CA aprovada. O modo comum só usa a confiança existente e não altera o ambiente.

Erros distinguem DNS, TCP, timeout, TLS, HTTP e corpo inesperado sem imprimir
respostas arbitrárias ou credenciais. O `--check` da etapa 80 usa a API do
cluster e o estado local da última reconciliação, sem chamadas ao Rancher ou
nova descoberta DNS/CA. Depois de mudar o ambiente, execute o modo normal para
reconciliar antes de verificar.

O Flannel padrão não aplica NetworkPolicy. Habilite isolamento de projetos
somente após adicionar um controlador compatível.

Referências oficiais:

- [Matriz Rancher v2.15.2](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/rancher-v2-15-2/).
- [Registro de clusters Generic](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup/register-existing-clusters).
- [Agent TLS Enforcement](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/installation-references/tls-settings).
- [Atualização de certificados Rancher](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/update-rancher-certificate).
- [Encaminhamento DNS](https://coredns.io/plugins/forward/).
