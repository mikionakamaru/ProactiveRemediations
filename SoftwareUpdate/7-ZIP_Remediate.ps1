<#
.SYNOPSIS
Microsoft Intune remediation script for 7-Zip update deployment.

.DESCRIPTION
Updates 7-Zip to version 26.02 by removing previous installations
and deploying the approved target version.

The script handles:
- Existing MSI installations
- User-scoped installations
- Machine-scoped installations
- Residual installation artifacts
- Post-installation validation

Target Version:
7-Zip 26.02

.AUTHOR
Mikio Nakamaru

.VERSION
1.0
#>

# --- CONFIGURACOES ---
$TargetVersion = [Version]"26.2.0.0"
$LogDir        = "$env:ProgramData\7-Zip"
$LogPath       = "$LogDir\7ZipUpdate.log"
$MsiLogPath    = "$LogDir\7ZipMsi.log"
$TempDir       = "$env:TEMP\7ZipUpdate"

$DownloadURLs64 = @(
    "https://www.7-zip.org/a/7z2602-x64.msi",
    "https://github.com/ip7z/7zip/releases/download/26.02/7z2602-x64.msi"
)
$DownloadURLs32 = @(
    "https://www.7-zip.org/a/7z2602.msi",
    "https://github.com/ip7z/7zip/releases/download/26.02/7z2602.msi"
)

$Is64Bit       = [Environment]::Is64BitOperatingSystem
$DownloadURLs  = if ($Is64Bit) { $DownloadURLs64 } else { $DownloadURLs32 }
$InstallerName = if ($Is64Bit) { "7z2602-x64.msi" } else { "7z2602.msi" }
$InstallerPath = Join-Path $TempDir $InstallerName

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

# --- VERSAO ---
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

# --- DESCOBERTA: ARP (Painel de Controle) ---
function Get-UninstallHives {
    $hives = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        try { New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -ErrorAction Stop | Out-Null }
        catch { }
    }
    try {
        $userSids = Get-ChildItem "HKU:\" -ErrorAction SilentlyContinue |
                    Where-Object { $_.PSChildName -match '^S-1-5-21-' }
        foreach ($sid in $userSids) {
            $hives += "HKU:\$($sid.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            $hives += "HKU:\$($sid.PSChildName)\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        }
    } catch { }
    return $hives
}

function Get-7ZipArpEntries {
    $result = @()
    foreach ($hive in (Get-UninstallHives)) {
        try {
            $entries = Get-ItemProperty -Path "$hive\*" -ErrorAction SilentlyContinue |
                       Where-Object {
                           $_.DisplayName -like "7-Zip*" -and
                           ($_.Publisher -like "*Igor Pavlov*" -or -not $_.Publisher)
                       }
            if ($entries) { $result += $entries }
        } catch { }
    }
    return $result
}

# --- DESCOBERTA: base interna do Windows Installer (produtos fantasma) ---
function Get-7ZipMsiProducts {
    # Retorna ProductCodes de 7-Zip registrados no Windows Installer,
    # inclusive os que perderam a entry de ARP.
    $found = @()
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $products = $installer.GetType().InvokeMember(
            'Products','GetProperty',$null,$installer,$null)

        foreach ($code in $products) {
            try {
                $name = $installer.GetType().InvokeMember(
                    'ProductInfo','GetProperty',$null,$installer,@($code,'ProductName'))
                if ($name -notlike "*7-Zip*") { continue }

                $ver = $null
                try {
                    $ver = $installer.GetType().InvokeMember(
                        'ProductInfo','GetProperty',$null,$installer,@($code,'VersionString'))
                } catch { }

                $found += [pscustomobject]@{
                    ProductCode = $code
                    Name        = $name
                    Version     = $ver
                }
            } catch { }
        }
    } catch {
        Write-Log "AVISO: nao foi possivel consultar WindowsInstaller COM: $($_.Exception.Message)"
    }
    return $found
}

# --- DESCOBERTA: disco ---
function Get-7ZipDiskVersion {
    $exes = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($exe in $exes) {
        if (Test-Path $exe) {
            $v = (Get-Item $exe).VersionInfo.FileVersion
            $norm = ConvertTo-NormalizedVersion -Raw $v
            if ($norm) { return [pscustomobject]@{ Path = $exe; Version = $norm } }
        }
    }
    return $null
}

function Write-CurrentState {
    param([string]$Rotulo)
    $arp  = @(Get-7ZipArpEntries)
    $msi  = @(Get-7ZipMsiProducts)
    $disk = Get-7ZipDiskVersion

    Write-Log "--- Estado ($Rotulo) ---"
    Write-Log "  ARP: $($arp.Count) entry(ies)"
    $arp | ForEach-Object { Write-Log "    - $($_.DisplayName) v$($_.DisplayVersion)" }
    Write-Log "  MSI registrados: $($msi.Count)"
    $msi | ForEach-Object { Write-Log "    - $($_.Name) v$($_.Version) $($_.ProductCode)" }
    if ($disk) { Write-Log "  Disco: v$($disk.Version) em $($disk.Path)" }
    else       { Write-Log "  Disco: nenhum 7z.exe encontrado" }
}

function Close-7Zip {
    $procs = Get-Process -Name "7zFM","7z","7zG" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Encerrando $($procs.Count) processo(s) do 7-Zip"
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# --- ESPERA DO UNINSTALLER NSIS (assincrono) ---
function Wait-ForNsisUninstaller {
    param(
        [string]$InstallDir,
        [int]$TimeoutSeconds = 180
    )
    $nsisNames = @("Au_", "Un_A", "Un_B", "Un_C", "Un", "uninstall", "Uninstall")
    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)

    Write-Log "  Aguardando uninstaller NSIS relocado terminar..."

    $sawProcess = $false
    while ((Get-Date) -lt $deadline) {
        $running = Get-Process -Name $nsisNames -ErrorAction SilentlyContinue
        if ($running) {
            if (-not $sawProcess) {
                $names = ($running | Select-Object -ExpandProperty Name -Unique) -join ', '
                Write-Log "  Processo NSIS detectado: $names"
                $sawProcess = $true
            }
            Start-Sleep -Seconds 2
            continue
        }
        break
    }
    if ($sawProcess) { Write-Log "  Processo NSIS finalizado" }

    $stableCount = 0
    $lastCount   = -1
    while ((Get-Date) -lt $deadline -and $stableCount -lt 3) {
        $count = 0
        if (Test-Path $InstallDir) {
            try { $count = @(Get-ChildItem -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue).Count }
            catch { $count = -2 }
        }
        if ($count -eq $lastCount) { $stableCount++ } else { $stableCount = 0 }
        $lastCount = $count
        Start-Sleep -Seconds 2
    }

    if (Test-Path $InstallDir) { Write-Log "  Diretorio estabilizou com $lastCount item(ns)" }
    else                       { Write-Log "  Diretorio $InstallDir removido" }

    Start-Sleep -Seconds 3
}

# --- DESINSTALACAO ---
function Uninstall-MsiProduct {
    param([string]$ProductCode, [string]$Label)
    Write-Log "  -> msiexec /x $ProductCode ($Label)"
    try {
        $p = Start-Process -FilePath "msiexec.exe" `
                           -ArgumentList @("/x", $ProductCode, "/qn", "/norestart", "REBOOT=ReallySuppress") `
                           -Wait -PassThru -NoNewWindow -ErrorAction Stop
        Write-Log "     exit code: $($p.ExitCode)"
        Start-Sleep -Seconds 3
        return ($p.ExitCode -in @(0, 1605, 1614, 3010))
    } catch {
        Write-Log "     erro: $($_.Exception.Message)"
        return $false
    }
}

function Uninstall-ArpEntry {
    param($Install)

    $name        = $Install.DisplayName
    $ver         = $Install.DisplayVersion
    $code        = $Install.PSChildName
    $uninstStr   = $Install.UninstallString
    $quietUninst = $Install.QuietUninstallString

    Write-Log "Desinstalando: $name v$ver"
    Write-Log "  PSChildName: $code"
    if ($uninstStr) { Write-Log "  UninstallString: $uninstStr" }

    # --- MSI por ProductCode ---
    if ($code -match '^\{[0-9A-Fa-f\-]+\}$') {
        return (Uninstall-MsiProduct -ProductCode $code -Label $name)
    }

    # --- NSIS Uninstall.exe (assincrono) ---
    $exePath = $null
    if ($quietUninst -and $quietUninst -match '([A-Za-z]:\\[^"]*?[Uu]ninstall\.exe)') {
        $exePath = $Matches[1]
    } elseif ($uninstStr -match '"([A-Za-z]:\\[^"]+[Uu]ninstall\.exe)"') {
        $exePath = $Matches[1]
    } elseif ($uninstStr -match '([A-Za-z]:\\[^"]*?[Uu]ninstall\.exe)') {
        $exePath = $Matches[1]
    }

    if ($exePath -and (Test-Path $exePath)) {
        $installDir = Split-Path $exePath -Parent
        Write-Log "  -> NSIS Uninstall.exe /S (assincrono)"
        try {
            Start-Process -FilePath $exePath -ArgumentList "/S" -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 3
            Wait-ForNsisUninstaller -InstallDir $installDir -TimeoutSeconds 180
            if (-not (Test-Path $Install.PSPath)) {
                Write-Log "  Entry do registro removida - confirmado"
                return $true
            }
            Write-Log "  AVISO: entry ainda presente apos NSIS"
        } catch {
            Write-Log "  Erro executando Uninstall.exe: $($_.Exception.Message)"
        }
    }

    # --- msiexec extraido da string ---
    if ($uninstStr -match 'msiexec.*(/[IXix])\s*(\{[0-9A-Fa-f\-]+\})') {
        return (Uninstall-MsiProduct -ProductCode $Matches[2] -Label $name)
    }

    # --- Entry orfa: SOMENTE se nao for produto MSI registrado ---
    # (apagar ARP de produto MSI cria o "produto fantasma" - nunca fazer isso)
    $msiProducts = @(Get-7ZipMsiProducts)
    if ($msiProducts.Count -eq 0 -and -not (Get-7ZipDiskVersion)) {
        Write-Log "  App ausente em disco e sem registro MSI - removendo entry orfa"
        try {
            Remove-Item -Path $Install.PSPath -Recurse -Force -ErrorAction Stop
            return $true
        } catch {
            Write-Log "  Erro removendo entry: $($_.Exception.Message)"
        }
    } else {
        Write-Log "  NAO removendo entry: ha registro MSI ou arquivos em disco"
    }

    Write-Log "  FALHA: nenhum metodo funcionou para $name"
    return $false
}

function Uninstall-All-7Zip {
    # Fase A: produtos MSI registrados (pega inclusive fantasmas sem ARP)
    $msiProducts = @(Get-7ZipMsiProducts)
    if ($msiProducts.Count -gt 0) {
        Write-Log "Removendo $($msiProducts.Count) produto(s) MSI registrado(s):"
        foreach ($prod in $msiProducts) {
            Write-Log "  $($prod.Name) v$($prod.Version)"
            Uninstall-MsiProduct -ProductCode $prod.ProductCode -Label $prod.Name | Out-Null
        }
        Start-Sleep -Seconds 3
    }

    # Fase B: entries de ARP restantes (tipicamente NSIS)
    $arp = @(Get-7ZipArpEntries)
    if ($arp.Count -gt 0) {
        Write-Log "Removendo $($arp.Count) entry(ies) de ARP restante(s):"
        foreach ($inst in $arp) { Uninstall-ArpEntry -Install $inst | Out-Null }
        Start-Sleep -Seconds 5
    }

    # Fase C: segunda passada
    $arp2 = @(Get-7ZipArpEntries)
    $msi2 = @(Get-7ZipMsiProducts)
    if ($arp2.Count -gt 0 -or $msi2.Count -gt 0) {
        Write-Log "Segunda passada (ARP: $($arp2.Count), MSI: $($msi2.Count))"
        foreach ($prod in $msi2) { Uninstall-MsiProduct -ProductCode $prod.ProductCode -Label $prod.Name | Out-Null }
        foreach ($inst in $arp2) { Uninstall-ArpEntry -Install $inst | Out-Null }
        Start-Sleep -Seconds 5
    }

    # Fase D: limpa diretorio residual (arquivos sem dono)
    $disk = Get-7ZipDiskVersion
    if ($disk) {
        $dir = Split-Path $disk.Path -Parent
        Write-Log "Removendo diretorio residual: $dir"
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # Verificacao final
    $arpF = @(Get-7ZipArpEntries)
    $msiF = @(Get-7ZipMsiProducts)
    if ($arpF.Count -gt 0 -or $msiF.Count -gt 0) {
        Write-Log "RESIDUO apos desinstalacao (ARP: $($arpF.Count), MSI: $($msiF.Count))"
        $arpF | ForEach-Object { Write-Log "  ARP: $($_.DisplayName) v$($_.DisplayVersion)" }
        $msiF | ForEach-Object { Write-Log "  MSI: $($_.Name) $($_.ProductCode)" }
        return $false
    }
    Write-Log "Desinstalacao completa - nenhum residuo"
    return $true
}

# --- DOWNLOAD ---
function Invoke-DownloadWithRetry {
    param(
        [string[]]$Urls,
        [string]$Destination,
        [int]$MaxAttemptsPerUrl = 2
    )
    foreach ($url in $Urls) {
        for ($i = 1; $i -le $MaxAttemptsPerUrl; $i++) {
            try {
                Write-Log "Download tentativa ${i}/${MaxAttemptsPerUrl}: $url"
                Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing `
                                  -TimeoutSec 120 -MaximumRedirection 5 -ErrorAction Stop
                if (Test-Path $Destination) {
                    $size = (Get-Item $Destination).Length
                    $fs = [System.IO.File]::OpenRead($Destination)
                    $header = New-Object byte[] 4
                    $fs.Read($header, 0, 4) | Out-Null
                    $fs.Close()
                    $hex = ($header | ForEach-Object { $_.ToString('X2') }) -join ' '

                    if ($size -gt 500000 -and $hex -eq 'D0 CF 11 E0') {
                        Write-Log "Download OK ($([math]::Round($size/1MB,2)) MB, header $hex)"
                        return $true
                    }
                    Write-Log "Arquivo invalido: $size bytes, header '$hex'"
                    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                }
            } catch {
                Write-Log "Erro no download: $($_.Exception.Message)"
            }
            if ($i -lt $MaxAttemptsPerUrl) { Start-Sleep -Seconds (5 * $i) }
        }
        Write-Log "Falhou em $url, tentando proxima URL..."
    }
    return $false
}

# --- INSTALACAO ---
function Install-7Zip {
    param([switch]$ForceReinstall)

    $modo = if ($ForceReinstall) { "REINSTALL forcado" } else { "instalacao normal" }
    Write-Log "Instalando $InstallerName ($modo)"

    $msiArgs = @("/i", "`"$InstallerPath`"", "/qn", "/norestart", "REBOOT=ReallySuppress")
    if ($ForceReinstall) {
        # vomus: reescreve arquivos por versao, sobrescreve mais antigos ou iguais,
        # e reescreve todas as chaves de registro (user + machine)
        $msiArgs += @("REINSTALL=ALL", "REINSTALLMODE=vomus")
    }
    $msiArgs += @("/l*v", "`"$MsiLogPath`"")

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs `
                           -Wait -PassThru -NoNewWindow -ErrorAction Stop
        $sw.Stop()
        $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Write-Log "msiexec exit code: $($p.ExitCode) (duracao: ${secs}s)"

        if ($secs -lt 3) {
            Write-Log "AVISO: duracao < 3s. Provavel maintenance mode (no-op)."
        }

        if ($p.ExitCode -notin @(0, 1641, 3010)) {
            Write-Log "FALHA msiexec. Ultimas linhas do log MSI:"
            if (Test-Path $MsiLogPath) {
                Get-Content $MsiLogPath -Tail 25 -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Log "  MSI> $_" }
            }
            return $false
        }
        return $true
    } catch {
        $sw.Stop()
        Write-Log "Excecao na instalacao: $($_.Exception.Message)"
        return $false
    }
}

function Test-InstallSuccess {
    # Considera sucesso apenas se ARP E disco concordam na versao alvo
    $arp = @(Get-7ZipArpEntries)
    $arpVer = $null
    foreach ($a in $arp) {
        $v = ConvertTo-NormalizedVersion -Raw $a.DisplayVersion
        if ($v -and (-not $arpVer -or $v -gt $arpVer)) { $arpVer = $v }
    }
    $disk = Get-7ZipDiskVersion

    Write-Log "Verificacao: ARP=$(if($arpVer){$arpVer}else{'nenhuma'}) | Disco=$(if($disk){$disk.Version}else{'nenhuma'})"

    if (-not $arpVer) { Write-Log "  ARP vazio - instalacao nao registrada"; return $false }
    if (-not $disk)   { Write-Log "  Disco vazio - arquivos nao instalados"; return $false }
    if ($arpVer -lt $TargetVersion)      { Write-Log "  ARP abaixo do alvo"; return $false }
    if ($disk.Version -lt $TargetVersion) { Write-Log "  Disco abaixo do alvo"; return $false }
    return $true
}

# ============================================================
# EXECUCAO
# ============================================================
Write-Log "=========================================="
Write-Log "7-Zip remediation v8 - Maquina: $env:COMPUTERNAME"
Write-Log "Alvo: 7-Zip 26.02 ($TargetVersion) x$(if($Is64Bit){'64'}else{'86'})"

Write-CurrentState -Rotulo "antes"

Close-7Zip

if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }

# ---- Desinstalacao ----
$uninstallOk = Uninstall-All-7Zip
Write-CurrentState -Rotulo "pos-desinstalacao"

if (-not $uninstallOk) {
    Write-Log "AVISO: residuos detectados. Vamos tentar instalar com REINSTALL forcado."
}

Write-Log "Aguardando 10s antes de instalar"
Start-Sleep -Seconds 10

# ---- Download ----
if (-not (Invoke-DownloadWithRetry -Urls $DownloadURLs -Destination $InstallerPath)) {
    Write-Log "FALHA: download nao concluiu em nenhum mirror"
    Exit 1
}

# ---- Instalacao ----
# Tentativa 1: normal. Tentativa 2: REINSTALL=ALL REINSTALLMODE=vomus,
# que forca o msiexec a reescrever arquivos e registro mesmo em maintenance mode.
$installOk = $false

if (Install-7Zip) {
    Start-Sleep -Seconds 5
    if (Test-InstallSuccess) { $installOk = $true }
    else { Write-Log "Primeira tentativa nao validou. Partindo para REINSTALL forcado." }
}

if (-not $installOk) {
    Start-Sleep -Seconds 5
    if (Install-7Zip -ForceReinstall) {
        Start-Sleep -Seconds 5
        if (Test-InstallSuccess) { $installOk = $true }
    }
}

# ---- Resultado ----
Write-CurrentState -Rotulo "final"

if ($installOk) {
    $sobras = @(Get-7ZipArpEntries | Where-Object {
        $v = ConvertTo-NormalizedVersion -Raw $_.DisplayVersion
        $v -and $v -lt $TargetVersion
    })
    if ($sobras.Count -gt 0) {
        Write-Log "AVISO: $($sobras.Count) instalacao(oes) antigas ainda presentes"
        $sobras | ForEach-Object { Write-Log "  - $($_.DisplayName) v$($_.DisplayVersion)" }
        Exit 1
    }
    Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "SUCESSO - 26.02 instalada, registrada e sem sobras"
    Exit 0
}

Write-Log "FALHA - instalacao nao validou apos 2 tentativas"
Write-Log "Log do MSI em $MsiLogPath | TempDir preservado em $TempDir"
Exit 1
