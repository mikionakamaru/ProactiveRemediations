<#
.SYNOPSIS
Microsoft Intune detection script for Notepad++ update compliance.

.DESCRIPTION
Detects Notepad++ installations and verifies whether the
installed version meets the approved security baseline.

This script is designed for Intune Remediations and identifies
devices that require an update to Notepad++ version
8.9.6 or later.

.AUTHOR
Mikio Nakamaru

.CATEGORY
Software Update

.PLATFORM
Microsoft Intune Remediations

.TARGET SOFTWARE
Notepad++

.MINIMUM VERSION
8.9.6

.VERSION
1.0
#>
$MinVersion = [Version]"8.9.6"

function Normalize-Version {
    param([string]$Raw)
    $clean = $Raw -replace '[^\d.]', ''
    $parts = $clean.Split('.') | ForEach-Object { [int]$_ }
    while ($parts.Count -lt 4) { $parts += 0 }
    return "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
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

$items = @()
foreach ($i in (Get-NppInstalls)) {
    if ($i.DisplayVersion) { $items += @{ Versao = $i.DisplayVersion } }
}

if ($items.Count -eq 0) {
    $exes = @(
        "$env:ProgramFiles\Notepad++\notepad++.exe",
        "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe"
    )
    foreach ($exe in $exes) {
        if (Test-Path $exe) {
            $v = (Get-Item $exe).VersionInfo.FileVersion
            if ($v) { $items += @{ Versao = $v }; break }
        }
    }
}

if ($items.Count -eq 0) {
    Write-Output "OK - Notepad++ nao encontrado neste dispositivo."
    Exit 0
}

$nok = $false
foreach ($item in $items) {
    try {
        $norm = Normalize-Version -Raw $item.Versao
        $v = [Version]$norm
        if ($v -lt $MinVersion) {
            Write-Output "NOK - Notepad++ $($item.Versao) vulneravel. Minimo exigido: $MinVersion"
            $nok = $true
        } else {
            Write-Output "OK - Notepad++ $($item.Versao) atualizado."
        }
    } catch {
        Write-Output "NOK - Versao '$($item.Versao)' nao identificada. Remediacao necessaria."
        $nok = $true
    }
}

if ($nok) { Exit 1 } else { Exit 0 }
