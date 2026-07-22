<#
.SYNOPSIS
Microsoft Intune detection script for WinRAR update compliance.

.DESCRIPTION
Detects WinRAR installations and verifies whether the installed
version meets the approved security baseline.

This script is designed for Intune Remediations and identifies
devices that require an update to WinRAR version 7.23 or later.

On 32-bit operating systems, remediation is not triggered because
the approved target release is available only for 64-bit systems.

.AUTHOR
Mikio Nakamaru

.CATEGORY
Software Update

.PLATFORM
Microsoft Intune Remediations

.TARGET SOFTWARE
WinRAR

.MINIMUM VERSION
7.23

.VERSION
1.0
#>

$MinVersion = [Version]"7.23.0.0"

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
        $sids = Get-ChildItem "HKU:\" -ErrorAction SilentlyContinue |
                Where-Object { $_.PSChildName -match '^S-1-5-21-' }
        foreach ($sid in $sids) {
            $hives += "HKU:\$($sid.PSChildName)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
            $hives += "HKU:\$($sid.PSChildName)\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        }
    } catch { }
    return $hives
}

function Get-WinRarArpEntries {
    $result = @()
    foreach ($hive in (Get-UninstallHives)) {
        try {
            $entries = Get-ItemProperty -Path "$hive\*" -ErrorAction SilentlyContinue |
                       Where-Object { $_.DisplayName -like "WinRAR*" }
            if ($entries) { $result += $entries }
        } catch { }
    }
    return $result
}

function Get-WinRarDiskInfo {
    # Caminhos padrao + o que o registro do proprio WinRAR aponta
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

    foreach ($exe in $candidates) {
        if ($exe -and (Test-Path $exe)) {
            $vi = (Get-Item $exe).VersionInfo
            $norm = ConvertTo-NormalizedVersion -Raw $vi.FileVersion
            if ($norm) {
                return [pscustomobject]@{
                    Path    = $exe
                    Version = $norm
                    Raw     = $vi.FileVersion
                }
            }
        }
    }
    return $null
}

# ---------- Coleta ----------
$arp  = @(Get-WinRarArpEntries)
$disk = Get-WinRarDiskInfo

# ---------- Nao instalado ----------
if ($arp.Count -eq 0 -and -not $disk) {
    Write-Output "OK - WinRAR nao instalado neste dispositivo"
    Exit 0
}

$is64 = [Environment]::Is64BitOperatingSystem
Write-Output "ARP: $($arp.Count) | Disco: $(if($disk){"v$($disk.Version)"}else{'nenhum'}) | SO: x$(if($is64){'64'}else{'86'})"

# ---------- x86: sem caminho de atualizacao ----------
if (-not $is64) {
    Write-Output "OK (sem acao) - SO 32-bit. WinRAR nao publica build x86 desde a 7.01."
    Write-Output "  Tratar por substituicao de software ou upgrade do SO."
    Exit 0
}

$nok = $false

# ---------- Versoes no ARP ----------
foreach ($item in $arp) {
    $v = ConvertTo-NormalizedVersion -Raw $item.DisplayVersion
    if (-not $v) {
        Write-Output "NOK - versao invalida '$($item.DisplayVersion)' em $($item.DisplayName)"
        $nok = $true
        continue
    }
    if ($v -lt $MinVersion) {
        Write-Output "NOK - $($item.DisplayName) v$($item.DisplayVersion) < 7.23"
        $nok = $true
    } else {
        Write-Output "OK - $($item.DisplayName) v$($item.DisplayVersion)"
    }
}

# ---------- Versao em disco ----------
if ($disk -and $disk.Version -lt $MinVersion) {
    Write-Output "NOK - WinRAR.exe em disco v$($disk.Raw) < 7.23"
    $nok = $true
}

# ---------- Estado inconsistente ----------
if ($disk -and $arp.Count -eq 0) {
    Write-Output "NOK - WinRAR.exe em disco sem entry no Painel de Controle"
    $nok = $true
}

if ($nok) { Exit 1 } else { Exit 0 }
