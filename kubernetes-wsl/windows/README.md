# Utilitários CMD para Kubernetes no WSL 2

Esta pasta contém somente scripts `.cmd`. Não há PowerShell. A numeração indica uma sequência operacional recomendada, mas os scripts são independentes e podem ser executados isoladamente.

O objetivo principal é controlar quando o Headlamp fica acessível no Windows sem publicar o cluster na LAN, VPN ou rede corporativa.

## Modelo de rede e segurança

A única porta publicada por estes utilitários é:

| Origem | Destino | Finalidade |
|---|---|---|
| `https://localhost:30443` no Windows | `service/headlamp:443` no Kubernetes | interface web local |

O encaminhamento real é executado dentro do WSL pelo serviço systemd `k8s-headlamp-local.service`:

```text
navegador do Windows
  -> https://localhost:30443
  -> encaminhamento localhost do WSL 2
  -> kubectl port-forward --address=127.0.0.1
  -> Service ClusterIP do Headlamp
```

Os scripts não:

- criam `netsh portproxy`;
- alteram Windows Firewall;
- instalam ou configuram UFW;
- expõem `0.0.0.0`, endereço da LAN ou VPN;
- criam NodePort, LoadBalancer ou Ingress;
- publicam a API Kubernetes `6443` no Windows.

A API `6443`, as redes de Pods e as redes de Services continuam internas ao WSL. Como o Headlamp utiliza login automático com uma ServiceAccount administrativa, ele não deve ser publicado fora de `localhost`.

## Sequência recomendada

Depois da primeira instalação:

```bat
00-check-environment.cmd Ubuntu-26.04 30443
20-open-cluster-ports.cmd Ubuntu-26.04 30443
30-trust-headlamp-ca.cmd Ubuntu-26.04
40-open-headlamp.cmd 30443
```

Ao terminar o trabalho:

```bat
80-close-cluster-ports.cmd Ubuntu-26.04 30443
```

Para reabrir em outro momento:

```bat
20-open-cluster-ports.cmd Ubuntu-26.04 30443
40-open-headlamp.cmd 30443
```

Para remover completamente a confiança local no certificado:

```bat
80-close-cluster-ports.cmd Ubuntu-26.04 30443
90-untrust-headlamp-ca.cmd
```

## Scripts

### `00-check-environment.cmd`

Executa verificações somente leitura:

1. confirma que `wsl.exe` está disponível;
2. confirma que a distribuição existe e utiliza WSL 2;
3. verifica se systemd é o PID 1;
4. verifica se `k8s-headlamp-local.service` foi instalado;
5. informa se o serviço está ativo e se o Headlamp responde no Windows.

Uso:

```bat
00-check-environment.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30443`.

Esse script não abre ou fecha portas. Consultar uma distribuição parada pode fazer o próprio `wsl.exe` iniciá-la, mas nenhuma configuração é alterada.

### `10-restart-wsl.cmd`

Encerra somente a distribuição informada com `wsl.exe --terminate` e a inicia novamente. Use após modificar `/etc/wsl.conf` ou `%UserProfile%\.wslconfig`.

Uso:

```bat
10-restart-wsl.cmd [DISTRIBUICAO]
```

Padrão: `Ubuntu-26.04`.

Esse script não executa `wsl.exe --shutdown`, portanto não encerra deliberadamente outras distribuições. Encerrar uma distribuição interrompe os processos que estiverem nela; salve trabalhos antes.

### `20-open-cluster-ports.cmd`

Habilita e inicia `k8s-headlamp-local.service`. O serviço executa o `kubectl port-forward` restrito a `127.0.0.1` dentro do WSL.

Uso:

```bat
20-open-cluster-ports.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30443`.

O script:

- valida que a unidade systemd existe;
- executa `systemctl enable --now` dentro do WSL;
- confirma que o serviço permaneceu ativo;
- testa `https://localhost:PORTA` com `curl.exe`, quando disponível.

O `enable` é intencional: depois de aberta, a porta volta a ficar disponível quando a distribuição reiniciar. Use o script `80` para mudar esse estado persistentemente para fechado.

O parâmetro `PORTA` serve para validar a porta configurada durante a instalação. Informar outra porta não reconfigura o cluster. Para trocar a porta real, ajuste `DASHBOARD_LOCAL_PORT` em `cluster.env` e reconcilie a instalação.

### `30-trust-headlamp-ca.cmd`

Importa a CA pública do Headlamp no repositório de certificados do usuário atual do Windows.

Uso:

```bat
30-trust-headlamp-ca.cmd [DISTRIBUICAO]
```

Padrão: `Ubuntu-26.04`.

O script:

- lê `/etc/kubernetes/pki/headlamp/ca.crt` dentro do WSL;
- grava uma cópia temporária em `%TEMP%`;
- valida que o arquivo contém um certificado PEM;
- importa com `certutil.exe -user`;
- apaga a cópia temporária em sucesso ou erro.

Somente o certificado público sai do WSL. A chave privada `/etc/kubernetes/pki/headlamp/ca.key` não é copiada. A opção `-user` limita a confiança ao usuário atual e normalmente dispensa elevação administrativa.

### `40-open-headlamp.cmd`

Testa a URL, quando `curl.exe` está disponível, e abre o navegador padrão.

Uso:

```bat
40-open-headlamp.cmd [PORTA]
```

Padrão: `30443`.

Esse script não cria encaminhamento. Se a porta estiver fechada, execute primeiro `20-open-cluster-ports.cmd`.

### `80-close-cluster-ports.cmd`

Para e desabilita `k8s-headlamp-local.service` por meio de `systemctl disable --now`.

Uso:

```bat
80-close-cluster-ports.cmd [DISTRIBUICAO] [PORTA]
```

Padrões: `Ubuntu-26.04` e `30443`.

O fechamento é persistente: o túnel não volta no próximo boot do WSL até que o script `20` seja executado. O script também testa se `localhost:PORTA` deixou de responder.

O cluster e seus Pods continuam funcionando dentro do WSL. Somente o acesso do Windows ao Headlamp é fechado. Como nenhuma regra de firewall ou `portproxy` é criada pelo projeto, não existe regra externa a remover.

### `90-untrust-headlamp-ca.cmd`

Remove do usuário atual do Windows a CA denominada `kubernetes-wsl-headlamp-ca`.

Uso:

```bat
90-untrust-headlamp-ca.cmd
```

Esse script não fecha portas nem remove certificados ou chaves do WSL. Normalmente ele só é necessário ao desativar o laboratório ou recriar sua autoridade certificadora.

## Arquivo `.wslconfig.example`

O arquivo oculto `.wslconfig.example` limita CPU, memória e swap e mantém `localhostForwarding=true` com rede NAT.

Para aplicá-lo ao usuário atual, execute no CMD a partir da raiz de `kubernetes-wsl`:

```bat
copy windows\.wslconfig.example "%UserProfile%\.wslconfig"
windows\10-restart-wsl.cmd Ubuntu-26.04
```

Revise os valores antes de copiar. `%UserProfile%\.wslconfig` afeta todas as distribuições WSL 2 do usuário.

## Privilégios

Os scripts foram projetados para CMD normal. Eles não invocam PowerShell.

- `certutil.exe -user` altera somente o repositório do usuário atual.
- `wsl.exe --user root` obtém privilégio apenas dentro da distribuição Linux.
- nenhuma regra do Windows Firewall é criada.

Se a política corporativa bloquear o próprio WSL ou `wsl.exe --user root`, abra CMD como administrador conforme a política da empresa ou solicite a habilitação à TI. Os scripts não tentam contornar políticas corporativas.

## Ajuda e códigos de saída

Todos os `.cmd` aceitam `/?` ou `--help`:

```bat
20-open-cluster-ports.cmd /?
```

Código `0` indica que a ação ou verificação principal terminou. Código diferente de `0` indica que nenhuma confirmação segura pôde ser obtida; leia a mensagem antes de repetir o comando.

Por segurança, `DISTRIBUICAO` aceita somente letras, números, ponto, sublinhado e hífen; nomes com espaços não são aceitos. `PORTA` aceita somente dígitos. Esses limites evitam que parâmetros sejam interpretados como comandos pelo CMD.

## Diagnóstico

Estado geral:

```bat
00-check-environment.cmd Ubuntu-26.04 30443
```

Logs do encaminhamento, sem PowerShell:

```bat
wsl.exe -d Ubuntu-26.04 --user root -- journalctl -u k8s-headlamp-local.service -n 100 --no-pager
```

Processo que ocupa a porta no Windows:

```bat
netstat.exe -ano | findstr.exe ":30443"
```

Se o serviço estiver ativo dentro do WSL, mas a URL não responder no Windows, confirme que `%UserProfile%\.wslconfig` contém:

```ini
[wsl2]
localhostForwarding=true
networkingMode=nat
```

Depois execute:

```bat
10-restart-wsl.cmd Ubuntu-26.04
20-open-cluster-ports.cmd Ubuntu-26.04 30443
```
