# Utilitários CMD para Kubernetes no WSL 2

Esta pasta contém somente scripts `.cmd`; nenhum deles usa PowerShell. A numeração representa a sequência operacional sugerida. Os scripts continuam independentes e aceitam `/?` ou `--help`.

Existem dois acessos locais e separados:

| URL no Windows | Serviço systemd no WSL | Destino interno | Uso |
|---|---|---|---|
| `https://localhost:30443` | `k8s-headlamp-local.service` | `service/headlamp:443` | administração pelo Headlamp |
| `http://localhost:30080` | `k8s-gateway-local.service` | Service Envoy gerado, porta `8080` | testar aplicações publicadas por `HTTPRoute`/`GRPCRoute` |

Ambos usam `kubectl port-forward --address=127.0.0.1`. Os scripts não criam regra de Windows Firewall, não instalam UFW, não usam `netsh portproxy` e não expõem `0.0.0.0`, LAN ou VPN. Os Services permanecem `ClusterIP`; a API Kubernetes `6443` também não é publicada por estes utilitários.

## Sequência recomendada

Verifique tudo:

```bat
00-check-environment.cmd Ubuntu-26.04 30443 30080
```

Se a instalação depender do bundle de contingência, importe-o antes de
executar `install-all.sh` no Ubuntu:

```bat
05-import-offline-bundle.cmd
```

Abra somente o que estiver usando:

```bat
20-open-cluster-ports.cmd Ubuntu-26.04 30443
25-open-gateway-port.cmd Ubuntu-26.04 30080
30-trust-headlamp-ca.cmd Ubuntu-26.04
40-open-headlamp.cmd 30443
45-test-gateway.cmd 30080
```

Ao terminar, feche os dois túneis de forma persistente:

```bat
75-close-gateway-port.cmd Ubuntu-26.04 30080
80-close-cluster-ports.cmd Ubuntu-26.04 30443
```

A CA do Headlamp pode permanecer confiável com as portas fechadas. Para removê-la do usuário atual:

```bat
90-untrust-headlamp-ca.cmd
```

## Scripts

### `00-check-environment.cmd`

Faz somente leitura. Confirma que a distribuição existe, usa WSL 2 e iniciou com systemd; verifica se as duas unidades de encaminhamento foram instaladas; informa se estão ativas; testa as duas URLs quando `curl.exe` existe.

```bat
00-check-environment.cmd [DISTRIBUICAO] [PORTA_HEADLAMP] [PORTA_GATEWAY]
```

Padrões: `Ubuntu-26.04`, `30443` e `30080`. Consultar uma distribuição parada pode iniciá-la, comportamento normal de `wsl.exe`, mas o script não inicia nem encerra os túneis.

### `05-import-offline-bundle.cmd`

Sem argumento, baixa do bucket S3 configurado no script o bundle e o checksum,
valida o SHA-256 com `certutil.exe` e extrai com `tar.exe` dentro de
`offline-cache`. O arquivo é preservado em `dist/`; execuções posteriores não
repetem o download grande se o hash publicado continuar igual. Não usa
PowerShell, não altera firewall, não exige administrador do Windows e não
inicia o cluster.

```bat
05-import-offline-bundle.cmd
05-import-offline-bundle.cmd ARQUIVO_TAR_GZ
```

Com argumento, usa o `.tar.gz` local e exige `ARQUIVO_TAR_GZ.sha256` ao lado.
O arquivo inclui `.deb`, Helm, Flannel e charts do Envoy, mas não inclui
imagens de contêiner. Além do SHA externo, a integridade interna e a
compatibilidade são verificadas pelo preflight Linux. Com
`ARTIFACT_MODE=auto`, o cache é contingência; com `ARTIFACT_MODE=cache`, ele é
obrigatório para esses artefatos.

### `10-restart-wsl.cmd`

Encerra somente a distribuição indicada com `wsl.exe --terminate` e a inicia novamente. Use depois de mudar `/etc/wsl.conf` ou `%UserProfile%\.wslconfig`.

```bat
10-restart-wsl.cmd [DISTRIBUICAO]
```

Padrão: `Ubuntu-26.04`. Salve trabalhos antes: encerrar a distribuição termina os processos Linux em execução. O script não usa `wsl.exe --shutdown`, portanto não encerra deliberadamente outras distribuições.

### `20-open-cluster-ports.cmd`

Habilita e inicia `k8s-headlamp-local.service`, preso a `127.0.0.1`. O `enable` é persistente: o Headlamp voltará no próximo boot do WSL até o script `80` ser executado.

```bat
20-open-cluster-ports.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30443`. A porta informada apenas valida a URL; para reconfigurá-la, mude `DASHBOARD_LOCAL_PORT` em `cluster.env` e reconcilie a instalação.

### `25-open-gateway-port.cmd`

Habilita e inicia `k8s-gateway-local.service`. A unidade descobre o Service Envoy gerado para `gateway-system/wsl-gateway` e encaminha `localhost:30080` para a porta interna `8080`.

```bat
25-open-gateway-port.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30080`. Uma resposta HTTP `404` é sucesso de conectividade quando nenhuma rota corresponde a `/`. Para mudar a porta real, altere `GATEWAY_LOCAL_PORT` em `cluster.env` e execute novamente `install-all.sh`.

### `30-trust-headlamp-ca.cmd`

Copia somente a CA pública `/etc/kubernetes/pki/headlamp/ca.crt` para um arquivo temporário, valida o PEM, importa no repositório do usuário atual com `certutil.exe -user` e remove a cópia temporária.

```bat
30-trust-headlamp-ca.cmd [DISTRIBUICAO]
```

Padrão: `Ubuntu-26.04`. A chave privada nunca sai do WSL. Em condições normais não é necessário CMD elevado.

### `40-open-headlamp.cmd`

Valida `https://localhost:PORTA` quando `curl.exe` existe e abre o navegador padrão. Não inicia o túnel nem altera certificados.

```bat
40-open-headlamp.cmd [PORTA]
```

Padrão: `30443`. Execute antes o script `20`.

### `45-test-gateway.cmd`

Faz um `GET /`, exibe os cabeçalhos HTTP do Envoy e não altera serviço algum.

```bat
45-test-gateway.cmd [PORTA]
```

Padrão: `30080`. HTTP `404` significa “Envoy acessível, nenhuma rota combinou”; erro de conexão significa que o túnel está fechado ou falhou. Para uma rota por prefixo, use diretamente `curl.exe http://localhost:30080/SEU_CAMINHO`.

### `75-close-gateway-port.cmd`

Executa `systemctl disable --now k8s-gateway-local.service` e espera a porta HTTP deixar de responder.

```bat
75-close-gateway-port.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30080`. Gateway, rotas, Envoy e aplicações continuam funcionando dentro do cluster; somente o acesso do Windows é fechado.

### `80-close-cluster-ports.cmd`

Executa `systemctl disable --now k8s-headlamp-local.service` e espera a porta HTTPS deixar de responder.

```bat
80-close-cluster-ports.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30443`. O fechamento é persistente e não para o cluster.

### `90-untrust-headlamp-ca.cmd`

Remove do repositório de certificados do usuário atual a CA `kubernetes-wsl-headlamp-ca`.

```bat
90-untrust-headlamp-ca.cmd
```

Não fecha portas nem apaga certificados no Linux. Use ao desativar o laboratório ou recriar a CA.

## `.wslconfig.example`

O arquivo limita CPU, memória e swap e mantém `localhostForwarding=true` em modo NAT. Revise os valores: `%UserProfile%\.wslconfig` afeta todas as distribuições WSL 2 do usuário.

```bat
copy .wslconfig.example "%UserProfile%\.wslconfig"
10-restart-wsl.cmd Ubuntu-26.04
```

## Privilégios e segurança de parâmetros

Os scripts foram feitos para CMD normal. `wsl.exe --user root` concede privilégio somente dentro da distribuição Linux. Se a empresa bloquear esse recurso ou o próprio WSL, use o fluxo aprovado pela TI; os scripts não tentam contornar políticas corporativas.

`DISTRIBUICAO` aceita somente letras, números, ponto, sublinhado e hífen. Parâmetros de porta aceitam somente dígitos. Essas restrições impedem que texto fornecido ao CMD seja interpretado como outro comando.

## Diagnóstico

Estado geral:

```bat
00-check-environment.cmd Ubuntu-26.04 30443 30080
```

Logs no WSL, ainda pelo CMD:

```bat
wsl.exe -d Ubuntu-26.04 --user root -- journalctl -u k8s-headlamp-local.service -n 100 --no-pager
wsl.exe -d Ubuntu-26.04 --user root -- journalctl -u k8s-gateway-local.service -n 100 --no-pager
```

Processos que ocupam as portas no Windows:

```bat
netstat.exe -ano | findstr.exe ":30443"
netstat.exe -ano | findstr.exe ":30080"
```

Se o serviço estiver ativo no WSL e a URL não responder no Windows, confirme em `%UserProfile%\.wslconfig`:

```ini
[wsl2]
localhostForwarding=true
networkingMode=nat
```

Depois reinicie apenas a distribuição e reabra o túnel necessário.
