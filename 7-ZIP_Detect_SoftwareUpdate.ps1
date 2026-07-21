<#
.SYNOPSIS
Microsoft Intune detection script for 7-Zip update compliance.

.DESCRIPTION
Detects installed 7-Zip instances and verifies compliance with
version 26.02 or later.

The script validates:
- Installed application inventory
- Windows Installer registration
- Executable version on disk

Any outdated, missing, or inconsistent installation state
triggers remediation.

.AUTHOR
Mikio Nakamaru

.VERSION
1.0
#>

$MinVersion = [Version]"26.2.0.0"

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

function Get-7ZipMsiProducts {
    $found = @()
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop
        $products = $installer.GetType().InvokeMember('Products','GetProperty',$null,$installer,$null)
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
                $found += [pscustomobject]@{ ProductCode = $code; Name = $name; Version = $ver }
            } catch { }
        }
    } catch { }
    return $found
}

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

# ---------- Coleta ----------
$arp  = @(Get-7ZipArpEntries)
$msi  = @(Get-7ZipMsiProducts)
$disk = Get-7ZipDiskVersion

# ---------- Caso 1: nada instalado em lugar nenhum ----------
if ($arp.Count -eq 0 -and $msi.Count -eq 0 -and -not $disk) {
    Write-Output "OK - 7-Zip nao instalado neste dispositivo"
    Exit 0
}

# ---------- Relatorio ----------
Write-Output "ARP: $($arp.Count) | MSI registrados: $($msi.Count) | Disco: $(if($disk){"v$($disk.Version)"}else{'nenhum'})"

$nok = $false

# ---------- Caso 2: versoes antigas no ARP ----------
foreach ($item in $arp) {
    $v = ConvertTo-NormalizedVersion -Raw $item.DisplayVersion
    if (-not $v) {
        Write-Output "NOK - versao invalida '$($item.DisplayVersion)' em $($item.DisplayName)"
        $nok = $true
        continue
    }
    if ($v -lt $MinVersion) {
        Write-Output "NOK - $($item.DisplayName) v$($item.DisplayVersion) < $MinVersion"
        $nok = $true
    } else {
        Write-Output "OK - $($item.DisplayName) v$($item.DisplayVersion)"
    }
}

# ---------- Caso 3: versoes antigas registradas no Windows Installer ----------
foreach ($prod in $msi) {
    $v = ConvertTo-NormalizedVersion -Raw $prod.Version
    if ($v -and $v -lt $MinVersion) {
        Write-Output "NOK - MSI registrado $($prod.Name) v$($prod.Version) < $MinVersion"
        $nok = $true
    }
}

# ---------- Caso 4: versao antiga em disco ----------
if ($disk -and $disk.Version -lt $MinVersion) {
    Write-Output "NOK - 7z.exe em disco v$($disk.Version) < $MinVersion"
    $nok = $true
}

# ---------- Caso 5: estado inconsistente (produto fantasma) ----------
# Arquivos em disco mas sem nenhuma entry no Painel de Controle
if ($disk -and $arp.Count -eq 0) {
    Write-Output "NOK - arquivos em disco (v$($disk.Version)) sem entry no Painel de Controle"
    $nok = $true
}

# Registrado no Windows Installer mas ausente do ARP
if ($msi.Count -gt 0 -and $arp.Count -eq 0) {
    Write-Output "NOK - produto MSI registrado sem entry no Painel de Controle (fantasma)"
    $nok = $true
}

# ARP diz uma coisa, disco diz outra
if ($disk -and $arp.Count -gt 0) {
    $arpMax = $null
    foreach ($a in $arp) {
        $v = ConvertTo-NormalizedVersion -Raw $a.DisplayVersion
        if ($v -and (-not $arpMax -or $v -gt $arpMax)) { $arpMax = $v }
    }
    if ($arpMax -and $arpMax -ne $disk.Version) {
        Write-Output "NOK - divergencia ARP (v$arpMax) vs disco (v$($disk.Version))"
        $nok = $true
    }
}

if ($nok) { Exit 1 } else { Exit 0 }
