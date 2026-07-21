<#
.SYNOPSIS
Microsoft Intune remediation script for Notepad++ updates.

.DESCRIPTION
Updates Notepad++ to the approved software version by removing
older releases and performing a silent installation.

This script is intended for Intune Remediations and performs:
- Installation discovery
- Legacy version removal
- Installer download
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
Notepad++

.TARGET VERSION
8.9.6

.VERSION
1.0
#>
$Is64Bit       = [Environment]::Is64BitOperatingSystem
$DownloadURL   = if ($Is64Bit) { "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.x64.exe" } else { "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.4/npp.8.9.4.Installer.exe" }
$InstallerName = if ($Is64Bit) { "npp.8.9.4.Installer.x64.exe" } else { "npp.8.9.4.Installer.exe" }
$LogPath       = "$env:ProgramData\Notepad++\NotepadUpdate.log"
$TempDir       = "$env:TEMP\NotepadPlusPlusUpdate"
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

function Get-NppVersion {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($p in $paths) {
        $e = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like "*Notepad++*" } |
             Select-Object -First 1
        if ($e -and $e.DisplayVersion) { return $e.DisplayVersion }
    }
    $exes = @(
        "$env:ProgramFiles\Notepad++\notepad++.exe",
        "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe"
    )
    foreach ($exe in $exes) {
        if (Test-Path $exe) { return (Get-Item $exe).VersionInfo.FileVersion }
    }
    return $null
}

function Get-NppInstalls {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $result = @()
    foreach ($p in $paths) {
        try {
            $e = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like "*Notepad++*" }
            if ($e) { $result += $e }
        } catch { }
    }
    return $result
}

function Close-Npp {
    Get-Process -Name "notepad++" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Log "Processos Notepad++ encerrados."
}

function Uninstall-OldNpp {
    $installs = Get-NppInstalls
    if ($installs.Count -eq 0) { Write-Log "Nenhuma versao anterior encontrada."; return }
    foreach ($i in $installs) {
        Write-Log "Desinstalando: $($i.DisplayName) v$($i.DisplayVersion)"
        if ($i.UninstallString) {
            $exe = $i.UninstallString -replace '"', '' -replace ' /.*$', ''
            if (Test-Path $exe) {
                $proc = Start-Process $exe -ArgumentList "/S" -Wait -PassThru -ErrorAction SilentlyContinue
                Write-Log "NSIS uninstall exit: $($proc.ExitCode)"
            }
        } elseif ($i.PSChildName -match "^\{[0-9A-Fa-f\-]+\}$") {
            $proc = Start-Process "msiexec.exe" -ArgumentList "/x `"$($i.PSChildName)`" /qn /norestart" -Wait -PassThru -ErrorAction SilentlyContinue
            Write-Log "MSI uninstall exit: $($proc.ExitCode)"
        }
    }
    Start-Sleep -Seconds 5
}

function Download-Installer {
    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    Write-Log "Baixando Notepad++ 8.9.4..."
    $maxRetries = 3
    for ($i = 1; $i -le $maxRetries; $i++) {
        Write-Log "Tentativa $i de $maxRetries..."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent","Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            $wc.DownloadFile($DownloadURL, $InstallerPath)
            if ((Test-Path $InstallerPath) -and (Get-Item $InstallerPath).Length -gt 4MB) {
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

function Install-Npp {
    Write-Log "Instalando Notepad++ 8.9.4..."
    try {
        $proc = Start-Process $InstallerPath -ArgumentList "/S /noUpdater" -Wait -PassThru -ErrorAction Stop
        Write-Log "Instalacao exit: $($proc.ExitCode)"
        if ($proc.ExitCode -eq 0) { return $true }
        Start-Sleep -Seconds 3
        if (Get-NppVersion) { return $true }
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
Write-Log "Notepad++ Update | Maquina: $env:COMPUTERNAME | Arq: $(if ($Is64Bit) {'64-bit'} else {'32-bit'})"
Write-Log "=========================================="

$before = Get-NppVersion
Write-Log "Versao atual: $(if ($before) {$before} else {'nao encontrada'})"

Close-Npp
Uninstall-OldNpp

if (-not (Download-Installer)) { Write-Log "NOK - Download falhou."; Exit 1 }

if (-not (Install-Npp)) { Cleanup; Write-Log "NOK - Instalacao falhou."; Exit 1 }

Start-Sleep -Seconds 5
$after = Get-NppVersion
Write-Log "Versao apos update: $(if ($after) {$after} else {'nao encontrada'})"

Cleanup
Write-Log "OK - Remediacao concluida."
Write-Log "=========================================="
Exit 0
