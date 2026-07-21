<#
.SYNOPSIS
Microsoft Intune remediation script for Mozilla Firefox updates.

.DESCRIPTION
Updates Mozilla Firefox to the latest approved version using
the official Mozilla installer.

This script is intended for Intune Remediations and performs:
- Installer download
- Browser process termination
- Silent installation
- Installation validation
- Temporary file cleanup

.AUTHOR
Mikio Nakamaru

.CATEGORY
Software Update

.PLATFORM
Microsoft Intune Remediations

.TARGET SOFTWARE
Mozilla Firefox

.TARGET VERSION
Latest Approved Release

.VERSION
1.0
#>
$LogPath       = "$env:ProgramData\Mozilla\FirefoxUpdate.log"
$TempDir       = "$env:TEMP\FirefoxUpdate"
$InstallerPath = Join-Path $TempDir "Firefox_Setup.exe"
$DownloadURL   = "https://download.mozilla.org/?product=firefox-latest-ssl&os=win64&lang=pt-BR"

$IniContent = "[Install]`r`nQuickLaunchShortcut=false`r`nDesktopShortcut=false`r`nStartMenuShortcuts=true`r`nMaintenanceService=true"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] $Message"
    Write-Output $line
    $logDir = Split-Path $LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
}

function Get-FirefoxVersion {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($p in $paths) {
        $e = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like "*Mozilla Firefox*" } |
             Select-Object -First 1
        if ($e -and $e.DisplayVersion) { return $e.DisplayVersion }
    }
    return $null
}

function Close-Firefox {
    $procs = Get-Process -Name "firefox" -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Log "Encerrando Firefox..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

function Download-Installer {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    Write-Log "Baixando Firefox de: $DownloadURL"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent","Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        $wc.DownloadFile($DownloadURL, $InstallerPath)
        if ((Test-Path $InstallerPath) -and (Get-Item $InstallerPath).Length -gt 1MB) {
            Write-Log "Download OK: $([math]::Round((Get-Item $InstallerPath).Length/1MB,2)) MB"
            return $true
        }
        Write-Log "NOK - Arquivo invalido apos download."
        return $false
    } catch {
        Write-Log "NOK - Erro no download: $($_.Exception.Message)"
        return $false
    }
}

function Install-Firefox {
    Write-Log "Instalando Firefox..."
    $iniPath = Join-Path $TempDir "install.ini"
    Set-Content -Path $iniPath -Value $IniContent -Encoding ASCII
    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList "/INI=`"$iniPath`"" -Wait -PassThru -ErrorAction Stop
        if ($proc.ExitCode -eq 0) { Write-Log "Instalacao OK. Exit: 0"; return $true }
        Write-Log "NOK - Instalacao retornou: $($proc.ExitCode)"
        return $false
    } catch {
        Write-Log "NOK - Excecao na instalacao: $($_.Exception.Message)"
        return $false
    }
}

function Cleanup {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "Temporarios removidos."
}

# --- MAIN ---
Write-Log "=========================================="
Write-Log "Firefox Update | Maquina: $env:COMPUTERNAME"
Write-Log "=========================================="

$before = Get-FirefoxVersion
Write-Log "Versao atual: $(if ($before) {$before} else {'nao encontrada'})"

Close-Firefox

if (-not (Download-Installer)) { Exit 1 }

if (-not (Install-Firefox)) { Cleanup; Exit 1 }

Start-Sleep -Seconds 5
$after = Get-FirefoxVersion
Write-Log "Versao apos update: $(if ($after) {$after} else {'nao encontrada'})"

Cleanup
Write-Log "OK - Remediacao concluida."
Write-Log "=========================================="
Exit 0
