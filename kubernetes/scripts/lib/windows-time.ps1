param(
    [ValidateSet('apply', 'check')][string]$Mode = 'check',
    [string]$NtpServers = '0.br.pool.ntp.org 1.br.pool.ntp.org 2.br.pool.ntp.org 3.br.pool.ntp.org',
    [int]$TimeoutSeconds = 120
)
$ErrorActionPreference = 'Stop'
$zone = [TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time')
function Write-TimeLog([string]$Message) {
    $stamp = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Now, $zone).ToString('yyyy-MM-ddTHH:mm:sszzz')
    Write-Output "[$stamp] $Message"
}
$servers = @($NtpServers -split '\s+' | Where-Object { $_ })
if (!$servers.Count -or $TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 9999) { throw 'Parametros NTP invalidos.' }
foreach ($server in $servers) { if ($server -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$') { throw 'Servidor NTP invalido.' } }
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Mode -eq 'apply') {
    # WSL sudo does not elevate Windows. An already prepared Windows host
    # remains usable from a normal WSL shell without reconfiguring its clock.
    $prior = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
    $priorPeers = @($prior.NtpServer -split '\s+' | Where-Object { $_ } | ForEach-Object { ($_ -split ',')[0] } | Sort-Object -Unique)
    $priorSource = (& w32tm.exe /query /source 2>$null | Out-String).Trim()
    if ((Get-TimeZone).Id -eq 'E. South America Standard Time' -and (Get-Service W32Time).Status -eq 'Running' -and
        $prior.Type -eq 'NTP' -and !(Compare-Object $priorPeers ($servers | Sort-Object -Unique)) -and
        $LASTEXITCODE -eq 0 -and ($servers -contains ($priorSource -split ',')[0])) {
        Write-TimeLog 'Windows Time ja esta sincronizado com a configuracao brasileira.'
        exit 0
    }
    if (!$isAdmin) { throw 'Execute este script em PowerShell Administrador antes de instalar no WSL.' }
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time') { throw 'Windows Time gerenciado por politica; ajuste a politica de NTP brasileira com o administrador.' }
    Set-TimeZone -Id 'E. South America Standard Time'
    Set-Service W32Time -StartupType Automatic
    Start-Service W32Time
    $peerList = ($servers | ForEach-Object { "$_,0x8" }) -join ' '
    & w32tm.exe /config "/manualpeerlist:$peerList" /syncfromflags:manual /update | Out-Null
    if ($LASTEXITCODE) { throw 'Falha ao configurar Windows Time.' }
    & w32tm.exe /resync /rediscover | Out-Null
    if ($LASTEXITCODE) { throw 'Windows Time nao sincronizou; confira DNS e UDP/123.' }
}
if ((Get-TimeZone).Id -ne 'E. South America Standard Time') { throw 'Fuso Windows deve ser America/Sao_Paulo (E. South America Standard Time).' }
if ((Get-Service W32Time).Status -ne 'Running') { throw 'Windows Time nao esta ativo.' }
$params = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
$configured = @($params.NtpServer -split '\s+' | ForEach-Object { ($_ -split ',')[0] } | Sort-Object -Unique)
if ($params.Type -ne 'NTP' -or (Compare-Object $configured ($servers | Sort-Object -Unique))) { throw 'Fontes Windows Time diferem do NTP brasileiro configurado.' }
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    $source = (& w32tm.exe /query /source 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and ($servers -contains ($source -split ',')[0])) {
        & w32tm.exe /query /status | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-TimeLog 'Windows Time validado com fonte NTP brasileira.'; exit 0 }
    }
    if ($Mode -eq 'check' -or [DateTime]::UtcNow -ge $deadline) { throw 'Windows Time sem fonte brasileira sincronizada.' }
    Start-Sleep -Seconds 2
} while ($true)
