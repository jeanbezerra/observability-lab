# Pré-instalação comum

As pastas `keycloak`, `kubernetes`, `kubernetes-wsl`, `kubernetes-hml` e `ranher`
contêm cópias idênticas destes helpers em `scripts/lib`. Cada pasta continua
funcionando sozinha ao ser copiada para uma VM. Edite a fonte nesta pasta e
sincronize os três arquivos com as cinco pastas; os testes detectam divergências.

Todo instalador completo e toda etapa numerada verificam o host antes de
instalar/reconciliar componentes. Os logs usam `America/Sao_Paulo` e ISO 8601
com offset, inclusive antes de corrigir o fuso do sistema. `--check` não muda
serviços, configurações de horário, partições, volumes ou filesystems.

O modo normal configura o serviço NTP já presente na imagem: Chrony no Ubuntu
26.04 ou systemd-timesyncd quando disponível. Usa os quatro pools brasileiros
`0.br.pool.ntp.org` a `3.br.pool.ntp.org`, espera sincronização real e bloqueia
a instalação se ela falhar. Confere a fonte selecionada em execução; no Chrony,
exige também correção restante inferior a meio segundo. Fontes diferentes na configuração Chrony ficam
comentadas, com backup; directives de funcionamento e includes são preservados.
Includes que introduzam outra fonte precisam ser corrigidos antes de continuar.
DNS e UDP/123 devem permitir acesso aos servidores. `SYSTEM_NTP_SERVERS` permite
usar servidores brasileiros próprios do ambiente. Não há instalação de pacotes
para contornar a verificação: Python 3, util-linux e um cliente NTP operacional
precisam fazer parte da imagem-base Ubuntu.

No WSL, Windows Time é a autoridade do relógio. Antes da primeira instalação,
execute em PowerShell **Administrador**:

```powershell
& .\kubernetes-wsl\scripts\lib\windows-time.ps1 -Mode apply
```

O instalador verifica Windows Time, o fuso Linux e uma diferença máxima de cinco
segundos entre os relógios. `sudo` no WSL não concede privilégios Windows.
Políticas corporativas de Windows Time exigem ajuste da política pelo seu
administrador; o helper não as sobrescreve.

`HOST_DISK_AUTO_EXPAND=true` é o padrão. Espaço não aproveitado significa
capacidade não alocada à raiz, não a existência de espaço livre para arquivos.
A verificação percorre disco → última partição → PV → VG → LV → filesystem.
O LV da raiz é identificado pelos números major/minor do dispositivo montado,
inclusive quando o mount usa `/dev/dm-N` ou um alias em `/dev/mapper`. Não depende
do nome do VG/LV; identificação ausente ou ambígua bloqueia qualquer expansão.
Em layout simples, expande a última partição raiz/PV, o PV, o LV raiz com todo
o espaço livre do seu VG e o ext4/XFS, sem apagar arquivos. São salvos a tabela
de partições e os metadados LVM antes da alteração. A expansão é permanente.

LVM com um PV e LV linear, partição simples e disco ext4 direto do WSL são
suportados. Outros discos não são tocados. Não move partições, não toma espaço
de outros LVs e não altera RAID, criptografia, thin pools, snapshots ou layouts
ambíguos. Se houver espaço inacessível ao fim do disco ou entre partições,
bloqueia e pede correção do layout. Alinhamento, headers GPT e metadados LVM
têm tolerância de até 8 MiB. A imagem deve conter `growpart`, `sfdisk`, LVM e
as ferramentas ext4/XFS quando seu layout necessitar expansão. O filesystem
virtual do WSL é verificado contra seu dispositivo virtual; o arquivo VHDX
continua esparso e não preenche o disco físico Windows com zeros.

Depois da expansão, os limites mínimos de espaço livre de cada produto ainda
se aplicam. Para desabilitar a expansão e apenas bloquear quando houver espaço
pendente, configure `HOST_DISK_AUTO_EXPAND=false`.

```bash
python3 installer-common/tests/test_host_storage.py
bash installer-common/tests/host-clock.sh
```

Referências: [NTP Pool brasileiro](https://www.ntppool.org/en/zone/br),
[Chrony no Ubuntu](https://documentation.ubuntu.com/server/how-to/networking/chrony-client/).
