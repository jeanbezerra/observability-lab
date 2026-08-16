# Keycloak 26.7 no Ubuntu 26.04 para Kubernetes e Headlamp

Este diretório instala uma instância Keycloak `26.7.1` em modo de produção sobre Ubuntu Server `26.04 LTS`, com OpenJDK 25, PostgreSQL 18 local, TLS obrigatório, serviço systemd, UFW, health checks, backup lógico e um realm OIDC pronto para centralizar o RBAC de clusters Kubernetes.

O instalador segue o mesmo modelo reconciliador do diretório `kubernetes/`: cada etapa possui `--check`, inspeciona o estado real, altera somente o que gerencia e valida o resultado. Reexecutar `install-all.sh` é a forma normal de concluir uma execução interrompida ou reconciliar uma mudança de configuração.

## Resultado

- Keycloak `26.7.1`, baixado da release oficial e validado por SHA-256;
- OpenJDK 25 suportado pelo Keycloak atual;
- PostgreSQL 18 em loopback, com database e role dedicados;
- autenticação PostgreSQL SCRAM-SHA-256 e role sem superuser, criação de DB/roles, replicação ou `BYPASSRLS`;
- HTTPS nativo na porta `8443` (ou porta configurada), sem HTTP público;
- certificado fornecido pelo administrador ou CA privada gerada localmente;
- health e métricas em `127.0.0.1:9000`, nunca liberados no UFW;
- cache de produção Infinispan com descoberta `jdbc-ping`;
- conta bootstrap temporária removida depois da criação da conta administrativa permanente;
- realm `platform`, cliente confidencial `kubernetes` e claim `groups` no ID token;
- grupos `k8s-viewers` e `k8s-admins`, sem usuários adicionados automaticamente;
- backup `pg_dump` diário, com checksum, verificação por `pg_restore --list` e retenção local;
- regras UFW limitadas aos CIDRs informados; PostgreSQL `5432` não é publicado.

```text
navegador do operador                    control plane Kubernetes
          |                                        |
          | OIDC authorization code                | discovery + JWKS
          v                                        v
  Keycloak HTTPS :8443 <----------------------------+
          |
          | JDBC em loopback
          v
  PostgreSQL 18 :5432 (não publicado)

Headlamp -- ID token --> kube-apiserver -- grupos oidc:* --> Kubernetes RBAC
```

Esta topologia é robusta para laboratório e ambiente local pequeno, mas não é altamente disponível: a perda do servidor interrompe novos logins. Tokens já emitidos continuam validáveis pelo API Server enquanto não expiram e enquanto a chave de assinatura permanecer no cache, mas isso não substitui HA.

## Pré-requisitos

- Ubuntu Server `26.04 LTS` amd64 ou arm64;
- 2 CPUs, 3 GiB de RAM e 10 GiB livres no mínimo;
- acesso root por `sudo`;
- DNS estável para o Keycloak, resolvível no próprio servidor, nos control planes e nos computadores dos operadores;
- IP fixo ou reserva DHCP;
- regra/NAT da rede externa, caso o acesso atravesse outro firewall;
- o URL HTTPS definitivo do Headlamp, pois ele será registrado como redirect URI.

O nome DNS é parte da identidade criptográfica do emissor. Depois que o cluster usar, por exemplo, `https://idp.lab.example.com:8443/realms/platform`, mudar host, porta, esquema ou realm produz outro issuer e invalida a integração existente.

## 1. Preparar DNS e TLS

Exemplo de DNS interno:

```text
idp.lab.example.com  A  192.168.1.40
k8s.lab.example.com  A  192.168.1.50
```

Há dois modos TLS:

| Modo | Uso | Configuração |
|---|---|---|
| `self-signed` | laboratório/rede privada | gera CA e certificado; copie a CA para cada cluster e cliente |
| `provided` | produção com PKI corporativa ou CA pública | informe certificado/fullchain, chave e CA em `TLS_*_FILE` |

Mesmo em rede privada, não use `start-dev` nem HTTP: tokens, códigos de autorização e cookies são credenciais.

## 2. Criar a configuração e os segredos

No servidor Keycloak:

```bash
cd keycloak
cp .env.example keycloak.env
cp .secrets.env.example secrets.env
chmod 600 keycloak.env secrets.env
vim keycloak.env
vim secrets.env
```

Gere quatro valores independentes:

```bash
openssl rand -base64 36  # KEYCLOAK_DB_PASSWORD
openssl rand -base64 36  # KEYCLOAK_ADMIN_PASSWORD
openssl rand -base64 36  # KEYCLOAK_BOOTSTRAP_PASSWORD
openssl rand -base64 48  # OIDC_CLIENT_SECRET
```

Não reutilize senhas. `secrets.env` é ignorado pelo Git, mas continua sendo um arquivo de configuração Bash controlado pelo administrador; mantenha-o com modo `0600` e não o envie por chat, log ou ticket.

Revise ao menos:

```bash
KEYCLOAK_HOSTNAME="idp.lab.example.com"
KEYCLOAK_SERVER_IP="192.168.1.40"
KEYCLOAK_HTTPS_PORT="8443"
HEADLAMP_EXTERNAL_URL="https://k8s.lab.example.com:30443"
KEYCLOAK_ALLOWED_CIDRS="192.168.0.0/16"
SSH_ALLOWED_CIDRS="192.168.0.0/16"
```

`KEYCLOAK_ALLOWED_CIDRS` deve conter tanto os IPs dos control planes quanto as redes dos navegadores. Separe redes com vírgula e sem espaços.

## 3. Instalar

```bash
sudo bash install-all.sh keycloak.env secrets.env
```

O instalador executa:

| Etapa | Responsabilidade |
|---|---|
| `00-preflight.sh` | valida SO, recursos, DNS, URLs, CIDRs, TLS e permissões dos segredos |
| `10-prepare-host.sh` | instala Java, PostgreSQL e utilitários; cria usuário/diretórios |
| `20-install-postgresql.sh` | cria role/database, força senha SCRAM e valida acesso local |
| `30-configure-tls.sh` | instala ou emite certificados e verifica SAN, chain e chave |
| `40-install-keycloak.sh` | baixa, valida SHA-256, extrai e gera build otimizado |
| `50-configure-service.sh` | instala o unit systemd endurecido e espera `health/ready` |
| `60-configure-realm.sh` | cria admin permanente, realm, grupos, cliente e mapper OIDC |
| `70-configure-firewall.sh` | preserva SSH e publica apenas o HTTPS nos CIDRs permitidos |
| `80-configure-backup.sh` | instala o backup lógico e o timer diário |
| `90-verify.sh` | testa banco, TLS, health, discovery, JWKS, realm, UFW e backup |

Para checar uma etapa sem alterar o host:

```bash
sudo env \
  KEYCLOAK_CONFIG_FILE="$(realpath keycloak.env)" \
  KEYCLOAK_SECRETS_FILE="$(realpath secrets.env)" \
  bash scripts/60-configure-realm.sh --check
```

## 4. Integrar o cluster Kubernetes e o Headlamp

Quando `TLS_MODE=self-signed`, copie a CA pública para o control plane. A chave da CA nunca deve sair do servidor Keycloak:

```bash
# Execute no control plane Kubernetes. O sudo remoto lê apenas a CA pública.
ssh administrador@idp.lab.example.com \
  'sudo cat /etc/keycloak/tls/ca.crt' > /root/keycloak-ca.crt
chmod 644 /root/keycloak-ca.crt
```

No diretório `kubernetes/` do control plane:

```bash
cp .env.example cluster.env
cp .oidc-secrets.env.example oidc-secrets.env
chmod 600 cluster.env oidc-secrets.env
vim cluster.env
vim oidc-secrets.env
```

Os valores precisam corresponder ao servidor:

```bash
ENABLE_OIDC="true"
OIDC_ISSUER_URL="https://idp.lab.example.com:8443/realms/platform"
OIDC_CLIENT_ID="kubernetes"
OIDC_CA_FILE="/root/keycloak-ca.crt" # vazio somente para CA pública/confiável
HEADLAMP_EXTERNAL_URL="https://k8s.lab.example.com:30443"
OIDC_VIEWER_GROUP="k8s-viewers"
OIDC_ADMIN_GROUP="k8s-admins"
OIDC_ENABLE_ADMIN_GROUP="true"
CREATE_ADMIN_SERVICE_ACCOUNT="false"
```

Em `oidc-secrets.env`, copie exatamente o `OIDC_CLIENT_SECRET` do `keycloak/secrets.env`:

```bash
HEADLAMP_OIDC_CLIENT_SECRET="MESMO_VALOR_DO_KEYCLOAK"
```

Execute o instalador do cluster:

```bash
sudo bash install-all.sh cluster.env oidc-secrets.env
```

A etapa `55-configure-oidc.sh` usa a API estável `AuthenticationConfiguration` do Kubernetes, instala a CA dentro de `/etc/kubernetes/pki/oidc`, adiciona `--authentication-config` ao Pod estático do API Server e aguarda o control plane voltar. Antes da alteração, salva o manifesto, a configuração e a CA anteriores em `/var/lib/k8s-bootstrap/backups`; se a API não voltar, restaura automaticamente o estado anterior.

Não combine `--authentication-config` com flags `--oidc-*`. O Kubernetes trata essa combinação como erro fatal; por isso o script detecta e recusa o conflito antes de tocar no manifesto.

## 5. Conceder acesso a usuários

Abra:

```text
https://idp.lab.example.com:8443/admin/
```

Entre com `KEYCLOAK_ADMIN_USER`, selecione o realm `platform`, crie ou sincronize usuários e associe-os a um dos grupos:

| Grupo Keycloak | Subject visto pelo Kubernetes | Permissão inicial |
|---|---|---|
| `k8s-viewers` | `oidc:k8s-viewers` | `view` + leitura de nodes, namespaces, PVs, storage e metrics; sem Secrets |
| `k8s-admins` | `oidc:k8s-admins` | `cluster-admin` quando `OIDC_ENABLE_ADMIN_GROUP=true` |

O grupo administrativo é deliberadamente poderoso. Para produção, prefira grupos por equipe/namespace e `RoleBinding` em vez de conceder `cluster-admin` amplamente.

Depois, acesse o Headlamp e clique em **Sign in**:

```text
https://k8s.lab.example.com:30443/?lng=pt
```

O Headlamp solicita `openid,profile,email`, recebe um ID token com a claim array `groups` e o apresenta ao API Server. O API Server prefixa usuário e grupos com `oidc:` e o RBAC decide o acesso; o Headlamp não mantém uma conta administrativa compartilhada.

## Firewall

| Porta | Bind/publicação | Finalidade |
|---|---|---|
| TCP `22` | `SSH_ALLOWED_CIDRS` | administração SSH |
| TCP `8443` | `KEYCLOAK_ALLOWED_CIDRS` | login, OIDC, Admin UI e Admin API |
| TCP `9000` | somente `127.0.0.1` | health e métricas |
| TCP `5432` | PostgreSQL localhost | banco Keycloak |
| TCP `7800/57800` | bloqueadas nesta topologia | transporte de cache; necessárias somente em projeto HA multi-instância |

Confira:

```bash
sudo ufw status numbered
sudo ss -ltnp | grep -E ':(8443|9000|5432)\b'
```

UFW não altera roteador, firewall corporativo, ACL de VLAN ou security group. Replique a liberação de `8443` na borda e não publique `9000`/`5432`.

## Verificações e operação

```bash
sudo systemctl status keycloak postgresql
sudo journalctl -u keycloak --since today
curl --cacert /etc/keycloak/tls/ca.crt \
  https://idp.lab.example.com:8443/realms/platform/.well-known/openid-configuration
curl -fsS http://127.0.0.1:9000/health/ready | jq
sudo bash scripts/90-verify.sh
```

O último comando precisa receber os mesmos arquivos de configuração quando eles não estiverem nos nomes padrão:

```bash
sudo env \
  KEYCLOAK_CONFIG_FILE="$(realpath keycloak.env)" \
  KEYCLOAK_SECRETS_FILE="$(realpath secrets.env)" \
  bash scripts/90-verify.sh
```

## Backups

O timer cria `/var/backups/keycloak/keycloak-AAAAMMDDTHHMMSSZ.dump` e o respectivo `.sha256`:

```bash
sudo systemctl list-timers keycloak-backup.timer
sudo systemctl start keycloak-backup.service
sudo journalctl -u keycloak-backup.service -n 50
sudo pg_restore --list /var/backups/keycloak/keycloak-*.dump | head
```

O dump local não é uma estratégia completa de recuperação. Copie-o criptografado para outro host/storage, defina RPO/RTO e ensaie periodicamente o restore em um PostgreSQL 18 isolado. Não restaure sobre a instância ativa sem janela, backup anterior e plano de reversão.

## Limites e próximos passos de produção

- A instalação é single-node; Keycloak e PostgreSQL são pontos únicos de falha.
- Não há PITR/WAL archiving, réplica PostgreSQL nem restore test automatizado.
- A Admin Console usa o mesmo hostname do frontend, mas o UFW restringe a rede. Em exposição pública, use reverse proxy/load balancer e hostname administrativo separado.
- O certificado privado é apropriado para rede interna; em uso público prefira PKI corporativa ou CA pública.
- Antes de adicionar uma segunda instância, projete load balancer, afinidade de sessão, portas de cache, banco altamente disponível e testes de failover.
- MFA/WebAuthn, SMTP para recuperação, federação LDAP/AD e políticas de senha dependem das políticas da organização e não são ativados automaticamente.

## Referências oficiais

- [Downloads do Keycloak](https://www.keycloak.org/downloads)
- [Configuração para produção](https://www.keycloak.org/server/configuration-production)
- [Configuração do banco](https://www.keycloak.org/server/db)
- [Configurações suportadas](https://www.keycloak.org/server/supported-configurations)
- [TLS no Keycloak](https://www.keycloak.org/server/enabletls)
- [Health checks](https://www.keycloak.org/observability/health)
- [Caches distribuídos](https://www.keycloak.org/server/caching)
- [Autenticação OIDC do Kubernetes](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)
- [OIDC no Headlamp](https://headlamp.dev/docs/latest/installation/in-cluster/oidc/)
