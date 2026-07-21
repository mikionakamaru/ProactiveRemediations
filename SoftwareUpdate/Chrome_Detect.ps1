<#
.SYNOPSIS
Microsoft Intune detection script for Google Chrome update compliance.

.DESCRIPTION
Detects Google Chrome installations and verifies whether the
installed version meets the approved security baseline.

This script is designed for Intune Remediations and identifies
devices that require an update to Google Chrome version
150.0.7871.115 or later.

.AUTHOR
Mikio Nakamaru

.TARGET SOFTWARE
Google Chrome

.MINIMUM VERSION
150.0.7871.115

.VERSION
1.0
#>
$MinVersion = [Version]"150.0.7871.115"

function Normalize-Version {
    param([string]$Raw)
    $clean = $Raw -replace '[^\d.]', ''
    $parts = $clean.Split('.') | ForEach-Object { [int]$_ }
    while ($parts.Count -lt 4) { $parts += 0 }
    return "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
}

function Get-ChromeInstalls {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $result = @()
    foreach ($p in $paths) {
        try {
            $e = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName -like "*Google Chrome*" }
            if ($e) { $result += $e }
        } catch { }
    }
    return $result
}

function Get-ChromeVersionFromExe {
    $exes = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($exe in $exes) {
        if (Test-Path $exe) {
            $v = (Get-Item $exe).VersionInfo.FileVersion
            if ($v) { return @{ Version = $v; Path = $exe } }
        }
    }
    return $null
}

# --- DETECCAO ---
$items = @()

foreach ($i in (Get-ChromeInstalls)) {
    if ($i.DisplayVersion) {
        $items += @{ Versao = $i.DisplayVersion; Origem = "Registro" }
    }
}

if ($items.Count -eq 0) {
    $exe = Get-ChromeVersionFromExe
    if ($exe) { $items += @{ Versao = $exe.Version; Origem = "EXE" } }
}

if ($items.Count -eq 0) {
    Write-Output "OK - Google Chrome nao encontrado neste dispositivo."
    Exit 0
}

$nok = $false

foreach ($item in $items) {
    try {
        $norm = Normalize-Version -Raw $item.Versao
        $v = [Version]$norm
        if ($v -lt $MinVersion) {
            Write-Output "NOK - Google Chrome $($item.Versao) vulneravel. Minimo exigido: $MinVersion"
            $nok = $true
        } else {
            Write-Output "OK - Google Chrome $($item.Versao) atualizado."
        }
    } catch {
        Write-Output "NOK - Versao '$($item.Versao)' nao identificada. Remediacao necessaria."
        $nok = $true
    }
}

if ($nok) { Exit 1 } else { Exit 0 }
