<#
.SYNOPSIS
Microsoft Intune remediation script for WinRAR updates.

.DESCRIPTION
Updates WinRAR to the approved software version while preserving
the existing installation language and license file when available.

This script is intended for Intune Remediations and performs:
- Installation discovery
- Architecture validation
- License backup and restore
- Installer language selection
- Installer download with hash validation
- Silent deployment
- Post-installation validation
- Temporary file cleanup

.AUTHOR
Mikio Nakamaru

.CATEGORY
Software Update

.PLATFORM
Microsoft Intune Remediations

.TARGET SOFTWARE
WinRAR

.TARGET VERSION
7.23

.VERSION
1.0
#>
# --- CONFIGURACOES ---
$TargetVersion = [Version]"7.23.0.0"
$LogDir        = "$env:ProgramData\WinRARUpdate"
$LogPath       = "$LogDir\WinRARUpdate.log"
$TempDir       = "$env:TEMP\WinRARUpdate"
$DefaultDir64  = "$env:ProgramFiles\WinRAR"

$IdiomaFallback = 'PTBR'

$Builds = @{
    'EN'   = @{
        Url  = 'https://www.win-rar.com/fileadmin/winrar-versions/winrar/winrar-x64-723.exe'
        Sha  = '0ED637A7897AAF428E9F5A6A8535FEC28C1828796782BAF0E4EA452B0CBE4F27'
        Nome = 'English'
    }
    'PTBR' = @{
        Url  = 'https://www.win-rar.com/fileadmin/winrar-versions/winrar/winrar-x64-723br.exe'
        Sha  = '84FF6A4A64082FEAB24C34345D7AC091ADC7E6A5EB1ED4487461D50C7D650F2F'
        Nome = 'Portugues Brasileiro'
    }
    'PT'   = @{
        Url  = 'https://www.win-rar.com/fileadmin/winrar-versions/winrar-x64-723pt.exe'
        Sha  = '39CF0012A3E135AB427537CDEAAE6E733AF3515F45629D78FAA53FF2DE2AC133'
        Nome = 'Portugues (Portugal)'
    }
    'ES'   = @{
        Url  = 'https://www.win-rar.com/fileadmin/winrar-versions/winrar/winrar-x64-723es.exe'
        Sha  = 'E504318097B512A91888781047FDF86BE563CA4E518E774B0D84FE7A38A54F04'
        Nome = 'Espanhol'
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- LOG ---
function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Output $line
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

function ConvertTo-NormalizedVersion {
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $clean = ($Raw -replace '[^\d.]', '').Trim('.')
    if (-not $clean) { return $null }
    $parts = @($clean.Split('.') | Where-Object { $_ -ne '' } | ForEach-Object {
        try { [int]$_ } catch { 0 }
    })
    while ($parts.Count -lt 4) { $parts += 0 }
    try { return [Version]"$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])" }
    catch { return $null }
}

# --- DESCOBERTA ---
function Get-WinRarArpEntries {
    $hives = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $result = @()
    foreach ($hive in $hives) {
        try {
            $e = Get-ItemProperty -Path "$hive\*" -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like "WinRAR*" }
            if ($e) { $result += $e }
        } catch { }
    }
    return $result
}

function Get-WinRarDiskInfo {
    $candidates = @(
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
    )
    foreach ($key in @("HKLM:\SOFTWARE\WinRAR", "HKLM:\SOFTWARE\WOW6432Node\WinRAR")) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            foreach ($v in @($p.exe64, $p.exe32)) {
                if ($v -and $v -notin $candidates) { $candidates += $v }
            }
        } catch { }
    }
    # InstallLocation do ARP tambem entra como candidato
    foreach ($a in (Get-WinRarArpEntries)) {
        if ($a.InstallLocation) {
            $c = Join-Path $a.InstallLocation "WinRAR.exe"
            if ($c -notin $candidates) { $candidates += $c }
        }
    }

    foreach ($exe in $candidates) {
        if ($exe -and (Test-Path $exe)) {
            $vi  = (Get-Item $exe).VersionInfo
            $dir = Split-Path $exe -Parent
            $norm = ConvertTo-NormalizedVersion -Raw $vi.FileVersion
            if (-not $norm) { continue }

            # Bitness: pelo caminho, com o ARP como reforco
            $bits = if ($dir -like "*Program Files (x86)*") { 32 } else { 64 }
            foreach ($a in (Get-WinRarArpEntries)) {
                if ($a.DisplayName -match '\(32-bit\)') { $bits = 32 }
                elseif ($a.DisplayName -match '\(64-bit\)') { $bits = 64 }
            }

            return [pscustomobject]@{
                Path            = $exe
                Dir             = $dir
                Version         = $norm
                Raw             = $vi.FileVersion
                FileDescription = $vi.FileDescription
                Language        = $vi.Language
                Bits            = $bits
            }
        }
    }
    return $null
}

# --- IDIOMA ---
function Get-IdiomaInstalado {
    param($DiskInfo)

    if (-not $DiskInfo) {
        Write-Log "Idioma: sem WinRAR em disco, usando fallback $IdiomaFallback"
        return $IdiomaFallback
    }

    Write-Log "Sinais de idioma:"
    Write-Log "  FileDescription: '$($DiskInfo.FileDescription)'"
    Write-Log "  VersionInfo.Language: '$($DiskInfo.Language)'"

    # Camada 1: idioma do resource de versao (sinal mais confiavel
    # observado nas builds localizadas)
    $lang = $DiskInfo.Language
    if ($lang) {
        if ($lang -match 'Portuguese \(Brazil') { Write-Log "  -> PTBR por Language"; return 'PTBR' }
        if ($lang -match 'Portuguese')          { Write-Log "  -> PT por Language";   return 'PT' }
        if ($lang -match 'Spanish')             { Write-Log "  -> ES por Language";   return 'ES' }
        if ($lang -match 'English')             { Write-Log "  -> EN por Language";   return 'EN' }
    }

    # Camada 2: FileDescription localizado (se a build traduzir)
    $fd = $DiskInfo.FileDescription
    if ($fd) {
        if ($fd -match 'Gerenciador|Compactador')      { Write-Log "  -> PTBR por FileDescription"; return 'PTBR' }
        if ($fd -match 'Administrador de archivos')    { Write-Log "  -> ES por FileDescription";   return 'ES' }
        if ($fd -match 'Gestor de ficheiros')          { Write-Log "  -> PT por FileDescription";   return 'PT' }
    }

    # Camada 3: locale da maquina
    try {
        $culture = (Get-Culture).Name
        Write-Log "  Locale da maquina: $culture"
        switch -Regex ($culture) {
            '^pt-BR' { Write-Log "  -> PTBR por locale"; return 'PTBR' }
            '^pt'    { Write-Log "  -> PT por locale";   return 'PT' }
            '^es'    { Write-Log "  -> ES por locale";   return 'ES' }
            '^en'    { Write-Log "  -> EN por locale";   return 'EN' }
        }
    } catch { }

    Write-Log "  -> sem sinal conclusivo, fallback $IdiomaFallback"
    return $IdiomaFallback
}

function Close-WinRar {
    $procs = Get-Process -Name "WinRAR","Rar","UnRAR" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Encerrando $($procs.Count) processo(s) do WinRAR"
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# --- DESINSTALACAO (para migracao de arquitetura) ---
function Wait-ForUninstall {
    param([string]$InstallDir, [int]$TimeoutSeconds = 120)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nomes = @("uninstall", "Au_", "Un_A", "Un_B")

    # Espera processos de desinstalacao sumirem
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Name $nomes -ErrorAction SilentlyContinue) {
            Start-Sleep -Seconds 2
            continue
        }
        break
    }

    # Espera o diretorio estabilizar
    $estavel = 0; $anterior = -1
    while ((Get-Date) -lt $deadline -and $estavel -lt 3) {
        $count = 0
        if (Test-Path $InstallDir) {
            try { $count = @(Get-ChildItem $InstallDir -Recurse -Force -ErrorAction SilentlyContinue).Count }
            catch { $count = -2 }
        }
        if ($count -eq $anterior) { $estavel++ } else { $estavel = 0 }
        $anterior = $count
        Start-Sleep -Seconds 2
    }

    if (Test-Path $InstallDir) { Write-Log "  Diretorio ainda existe com $anterior item(ns)" }
    else                       { Write-Log "  Diretorio $InstallDir removido" }
    Start-Sleep -Seconds 2
}

function Uninstall-WinRar {
    param($DiskInfo)

    $uninstExe = Join-Path $DiskInfo.Dir "uninstall.exe"

    # Se o ARP apontar outro caminho, prioriza ele
    foreach ($a in (Get-WinRarArpEntries)) {
        if ($a.UninstallString -match '([A-Za-z]:\\[^"]*?uninstall\.exe)') {
            $cand = $Matches[1]
            if (Test-Path $cand) { $uninstExe = $cand }
        }
    }

    if (-not (Test-Path $uninstExe)) {
        Write-Log "  uninstall.exe nao encontrado em $($DiskInfo.Dir)"
        return $false
    }

    Write-Log "  Executando: $uninstExe /S"
    try {
        Start-Process -FilePath $uninstExe -ArgumentList "/S" -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 3
        Wait-ForUninstall -InstallDir $DiskInfo.Dir
    } catch {
        Write-Log "  Erro no uninstall: $($_.Exception.Message)"
        return $false
    }

    $restante = Get-WinRarDiskInfo
    if ($restante -and $restante.Dir -eq $DiskInfo.Dir) {
        Write-Log "  AVISO: instalacao antiga ainda presente em $($DiskInfo.Dir)"
        return $false
    }
    Write-Log "  Desinstalacao do 32-bit concluida"
    return $true
}

# --- DOWNLOAD COM VALIDACAO DE HASH ---
function Invoke-DownloadVerified {
    param([string]$Url, [string]$ExpectedSha, [string]$Destination, [int]$MaxAttempts = 3)

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Write-Log "Download tentativa ${i}/${MaxAttempts}: $Url"
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing `
                              -TimeoutSec 180 -MaximumRedirection 5 -ErrorAction Stop

            if (-not (Test-Path $Destination)) { throw "arquivo nao foi criado" }

            $size = (Get-Item $Destination).Length
            $hash = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash.ToUpper()
            Write-Log "  Tamanho: $([math]::Round($size/1MB,2)) MB"
            Write-Log "  SHA256 obtido:   $hash"
            Write-Log "  SHA256 esperado: $($ExpectedSha.ToUpper())"

            if ($hash -eq $ExpectedSha.ToUpper()) {
                Write-Log "  Hash confere - binario integro"
                return $true
            }
            Write-Log "  HASH NAO CONFERE. Descartando."
            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "  Erro no download: $($_.Exception.Message)"
            Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        }
        if ($i -lt $MaxAttempts) { Start-Sleep -Seconds (5 * $i) }
    }
    return $false
}

# --- INSTALACAO ---
function Install-WinRar {
    param([string]$InstallerPath)

    $argLine = "/S"

    Write-Log "Executando: `"$InstallerPath`" $argLine"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath $InstallerPath -ArgumentList $argLine `
                           -Wait -PassThru -NoNewWindow -ErrorAction Stop
        $sw.Stop()
        $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Write-Log "Instalador exit code: $($p.ExitCode) (duracao: ${secs}s)"
        if ($secs -lt 2) { Write-Log "AVISO: duracao muito curta, pode nao ter feito nada" }
        return $true
    } catch {
        $sw.Stop()
        Write-Log "Excecao na instalacao: $($_.Exception.Message)"
        return $false
    }
}

Write-Log "=========================================="
Write-Log "WinRAR remediation v3 - Maquina: $env:COMPUTERNAME"
Write-Log "Alvo: WinRAR 7.23 ($TargetVersion) x64"

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Log "SO 32-bit. WinRAR nao publica build x86 desde a 7.01."
    Write-Log "Sem caminho de atualizacao. Tratar por substituicao de software."
    Exit 0
}

$antes    = Get-WinRarDiskInfo
$arpAntes = @(Get-WinRarArpEntries)

Write-Log "Estado antes: disco=$(if($antes){"v$($antes.Raw) x$($antes.Bits)"}else{'nenhum'}) | ARP=$($arpAntes.Count)"
$arpAntes | ForEach-Object { Write-Log "  ARP: $($_.DisplayName) v$($_.DisplayVersion)" }

if (-not $antes -and $arpAntes.Count -eq 0) {
    Write-Log "WinRAR nao instalado. Nada a fazer (por design)."
    Exit 0
}

if ($antes) { Write-Log "Diretorio atual: $($antes.Dir) (x$($antes.Bits))" }

$licencaBackup = $null
if ($antes) {
    $keyPath = Join-Path $antes.Dir "rarreg.key"
    if (Test-Path $keyPath) {
        if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
        $licencaBackup = Join-Path $TempDir "rarreg.key"
        Copy-Item $keyPath $licencaBackup -Force
        Write-Log "Licenca copiada para backup: $licencaBackup"
    } else {
        Write-Log "Sem rarreg.key (instalacao em modo trial)"
    }
}

$idioma = Get-IdiomaInstalado -DiskInfo $antes
$build  = $Builds[$idioma]
if (-not $build) {
    Write-Log "FALHA: idioma '$idioma' sem build no catalogo"
    Exit 1
}
Write-Log "Build escolhida: $($build.Nome)"

Close-WinRar
if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
$installer = Join-Path $TempDir ([System.IO.Path]::GetFileName($build.Url))

if (-not (Invoke-DownloadVerified -Url $build.Url -ExpectedSha $build.Sha -Destination $installer)) {
    Write-Log "FALHA: download nao passou na validacao de hash"
    Write-Log "Nada foi alterado na maquina. TempDir preservado em $TempDir"
    Exit 1
}

$migrando  = $false
$dirEsperado = $DefaultDir64

if ($antes -and $antes.Bits -eq 32) {
    $migrando = $true
    Write-Log "MIGRACAO x86 -> x64 necessaria (7.23 nao tem build 32-bit)"
    Write-Log "Removendo instalacao 32-bit em $($antes.Dir)"

    if (-not (Uninstall-WinRar -DiskInfo $antes)) {
        Write-Log "FALHA: nao foi possivel remover a instalacao 32-bit."
        Write-Log "Instalacao ABORTADA para nao deixar duas versoes em disco."
        Exit 1
    }
    Write-Log "Instalando x64 (destino padrao: $DefaultDir64)"
}
elseif ($antes) {
    $dirEsperado = $antes.Dir
    Write-Log "Atualizando no lugar (esperado: $($antes.Dir))"
}

if (-not (Install-WinRar -InstallerPath $installer)) {
    Write-Log "FALHA na execucao do instalador"
    Exit 1
}

Start-Sleep -Seconds 5

$depois = Get-WinRarDiskInfo
if ($licencaBackup -and (Test-Path $licencaBackup) -and $depois) {
    $destKey = Join-Path $depois.Dir "rarreg.key"
    if (-not (Test-Path $destKey)) {
        try {
            Copy-Item $licencaBackup $destKey -Force -ErrorAction Stop
            Write-Log "rarreg.key restaurado em $destKey"
        } catch {
            Write-Log "ALERTA: falha ao restaurar rarreg.key: $($_.Exception.Message)"
        }
    } else {
        Write-Log "rarreg.key ja presente apos a instalacao"
    }
}

$arpDepois = @(Get-WinRarArpEntries)
Write-Log "Estado depois: disco=$(if($depois){"v$($depois.Raw) x$($depois.Bits)"}else{'nenhum'}) | ARP=$($arpDepois.Count)"
$arpDepois | ForEach-Object { Write-Log "  ARP: $($_.DisplayName) v$($_.DisplayVersion)" }

$residuoX86 = "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe"
if ($migrando -and (Test-Path $residuoX86)) {
    Write-Log "AVISO: WinRAR.exe ainda presente em Program Files (x86)"
}

if ($depois -and $depois.Dir -ne $dirEsperado) {
    Write-Log "AVISO: instalado em $($depois.Dir), esperado $dirEsperado"
    Write-Log "  Verificar se a pasta antiga precisa de limpeza manual."
}

Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue

if ($depois -and $depois.Version -ge $TargetVersion) {
    $arpOk = $false
    foreach ($a in $arpDepois) {
        $v = ConvertTo-NormalizedVersion -Raw $a.DisplayVersion
        if ($v -and $v -ge $TargetVersion) { $arpOk = $true }
    }
    if (-not $arpOk) {
        Write-Log "AVISO: disco em 7.23 mas ARP nao reflete a versao"
        Exit 1
    }
    Write-Log "SUCESSO - WinRAR $($depois.Raw) x$($depois.Bits) ($($build.Nome))"
    Exit 0
}

Write-Log "FALHA - versao final $(if($depois){$depois.Raw}else{'nenhuma'}) nao atende 7.23"
Exit 1
