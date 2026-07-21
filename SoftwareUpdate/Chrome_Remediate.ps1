<#
.SYNOPSIS
Microsoft Intune remediation script for Google Chrome updates.

.DESCRIPTION
Updates Google Chrome to the latest approved enterprise version
using the official Google Enterprise MSI package.

This script is intended for Intune Remediations and performs:
- Download of the enterprise installer
- Browser process termination
- Silent installation
- Post-installation validation

.AUTHOR
Mikio Nakamaru

.TARGET SOFTWARE
Google Chrome

.TARGET VERSION
Latest Enterprise Release

.VERSION
1.0
#>
$Is64Bit       = [Environment]::Is64BitOperatingSystem
$DownloadURL   = if ($Is64Bit) { "https://dl.google.com/chrome/install/googlechromestandaloneenterprise64.msi" } else { "https://dl.google.com/chrome/install/googlechromestandaloneenterprise.msi" }
$InstallerName = if ($Is64Bit) { "ChromeEnterprise64.msi" } else { "ChromeEnterprise32.msi" }
$LogPath       = "$env:ProgramData\Google\ChromeUpdate.log"
$TempDir       = "$env:TEMP\ChromeUpdate"
$InstallerPath = Join-Path $TempDir $InstallerName

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Output $line
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

function Get-ChromeVersion {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($p in $paths) {
        $e = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like "*Google Chrome*" } |
             Select-Object -First 1
        if ($e -and $e.DisplayVersion) { return $e.DisplayVersion }
    }
    $exes = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($exe in $exes) {
        if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.FileVersion }
    }
    return $null
}

function Close-Chrome {
    Get-Process -Name "chrome","GoogleUpdate" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Log "Processos Chrome encerrados."
}

function Download-Installer {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    Write-Log "Baixando Chrome MSI Enterprise..."
    $maxRetries = 3
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-Log "Tentativa $i de $maxRetries..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent","Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            $wc.DownloadFile($DownloadURL, $InstallerPath)
            if ((Test-Path $InstallerPath) -and (Get-Item $InstallerPath).Length -gt 1MB) {
                Write-Log "Download OK: $([math]::Round((Get-Item $InstallerPath).Length/1MB,2)) MB"
                return $true
            }
            Write-Log "Arquivo invalido, tentando novamente..."
            Remove-Item $InstallerPath -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Erro tentativa $i : $($_.Exception.Message)"
        }
        if ($i -lt $maxRetries) { Start-Sleep -Seconds 10 }
    }
    return $false
}

function Install-Chrome {
    Write-Log "Instalando Chrome via MSI..."
    $msiLog = "$TempDir\chrome_install.log"
    $args = "/i `"$InstallerPath`" /qn /norestart REBOOT=ReallySuppress /l*v `"$msiLog`""
    try {
        $proc = Start-Process "msiexec.exe" -ArgumentList $args -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -in @(0,1641,3010)) {
            Write-Log "Instalacao OK. Exit: $($proc.ExitCode)"
            return $true
        }
        Write-Log "NOK - MSI retornou: $($proc.ExitCode)"
        if (Test-Path $msiLog) {
            $tail = Get-Content $msiLog -Tail 20 -ErrorAction SilentlyContinue
            Write-Log "MSI log: $($tail -join ' | ')"
        }
        return $false
    } catch {
        Write-Log "NOK - Excecao: $($_.Exception.Message)"
        return $false
    }
}

function Cleanup {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Temporarios removidos."
}

# --- MAIN ---
Write-Log "=========================================="
Write-Log "Chrome Update | Maquina: $env:COMPUTERNAME | Arq: $(if ($Is64Bit) {'64-bit'} else {'32-bit'})"
Write-Log "=========================================="

$before = Get-ChromeVersion
Write-Log "Versao atual: $(if ($before) {$before} else {'nao encontrada'})"

Close-Chrome

if (-not (Download-Installer)) { Write-Log "NOK - Download falhou."; Exit 1 }

if (-not (Install-Chrome)) { Cleanup; Exit 1 }

Start-Sleep -Seconds 5
$after = Get-ChromeVersion
Write-Log "Versao apos update: $(if ($after) {$after} else {'nao encontrada'})"

Cleanup
Write-Log "OK - Remediacao concluida."
Write-Log "=========================================="
Exit 0
