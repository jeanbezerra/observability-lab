# Validação offline

As regressões rodam com Bash e Python 3, sem sudo, rede ou cluster. Elas usam
diretórios temporários e fixtures para simular Kubernetes e Rancher.

Execute a partir da pasta `kubernetes-hml`:

```bash
bash tests/preflight-validation.sh
bash tests/gateway-external-access.sh
bash tests/rancher-dns.sh
bash tests/rancher-ca.sh
bash tests/rancher-version.sh
bash tests/rancher-registration.sh
find . -name '*.sh' -print0 | xargs -0 -n 1 bash -n
find . -name '*.sh' -print0 | xargs -0 shellcheck -x -P SCRIPTDIR
```

ShellCheck é uma ferramenta de desenvolvimento; não é necessário para instalar.
As regressões verificam configuração interativa/não interativa, recusa de WSL,
endereços/CIDRs/HTTPS, reconciliação NodePort, preservação de ClusterIP, recusa de
recursos de outro proprietário, registro Generic, TLS e proteção de credenciais.
O teste DNS cobre preservação do Corefile, encaminhamento por hostname,
idempotência, conflitos, backup e falhas de patch/rollout, inclusive recuperação.
Também verifica descoberta dos resolvedores reais e mudanças de ambiente.
Os testes TLS geram CAs efêmeras e servidores HTTPS locais para conferir
descoberta, pin, rejeição, cache e rotação. O teste de versão cobre descoberta
HTTPS, cache por URL, configuração explícita, divergência e modo sem rede.
Elas não comprovam instalação em VM, acesso de outra máquina ou estado Active
no Rancher. Esses pontos são verificados na implantação pelo instalador e pela
interface do Rancher, conforme o README.

`bash test-rancher.sh URL [ARQUIVO_CA]` é o teste real somente leitura do
endpoint HTTPS. A etapa de registro usa a mesma função; as regressões cobrem
sucesso, erros DNS/TCP/TLS/timeout, HTTP, redirecionamento e corpo inesperado.
