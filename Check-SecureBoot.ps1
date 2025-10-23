# Verifica TPM
$TpmInfo = Get-WmiObject -Class Win32_Tpm -Namespace "root\CIMv2\Security\MicrosoftTpm"
$TPMStatus = "NOK"
If ($TpmInfo.SpecVersion | Select-String "2.0," -Quiet) {
    $TPMStatus = "OK"
}

# Verifica Secure Boot
$SecureBootInfo = Confirm-SecureBootUEFI -ErrorAction SilentlyContinue
$SecureBootStatus = If ($SecureBootInfo -eq $true) { "OK" } else { "NOK" }

# Verifica Device Guard
$DeviceGuardInfo = (Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard).RequiredSecurityProperties
$DeviceGuardStatus = If ($DeviceGuardInfo -ne 0) { "OK" } else { "NOK" }

# Verifica DEP
$DEPInfo = (Get-CimInstance -ClassName Win32_OperatingSystem).DataExecutionPrevention_SupportPolicy
$DEPStatus = If ($DEPInfo -ne 0) { "OK" } else { "NOK" }

# Verifica CI (Code Integrity via registro)
$CIInfo = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -Name "Enabled" -ErrorAction SilentlyContinue
$CIStatus = If ($CIInfo.Enabled -eq 1) { "OK" } else { "NOK" }

# Verifica HVCI via WMI
$MIInfo = Get-WmiObject -Namespace "root\Microsoft\Windows\DeviceGuard" -Class "Win32_DeviceGuard" | Select-Object -ExpandProperty SecurityServicesRunning
$MIStatus = If ($MIInfo -contains 2) { "OK" } else { "NOK" }

# Verifica HVCI via registro
$IntegrityInfo = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\CI\State" -Name "HVCIEnabled" -ErrorAction SilentlyContinue
$IntegrityStatus = If ($IntegrityInfo.HVCIEnabled -eq 1) { "OK" } else { "NOK" }

# Verifica Credential Guard
$CredInfo = Get-WmiObject -Namespace "root\Microsoft\Windows\DeviceGuard" -Class "Win32_DeviceGuard" | Select-Object -ExpandProperty SecurityServicesRunning
$CredStatus = If ($CredInfo -contains 1) { "OK" } else { "NOK" }

# Verifica se há usuários de domínio logados
$AccountList = @()
$AllSID = Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "C:\Users\*" -and $_.Special -eq $false } | Select-Object -ExpandProperty SID
foreach ($SID in $AllSID) {
    try {
        $UserName = [System.Security.Principal.SecurityIdentifier]::new($SID).Translate([System.Security.Principal.NTAccount]).Value
        if ($UserName -match "^[^\\]

+\

\[^\\]

+$") {
            $AccountList += $UserName
        }
    } catch {
        Write-Host "SID desconhecido: $SID"
    }
}
$DomainUsr = If ($AccountList.Count -gt 0) { "OK" } else { "NOK" }

# Gera saída
$Output = "TPM=$TPMStatus;SB=$SecureBootStatus;DG=$DeviceGuardStatus;DEP=$DEPStatus;HVCIkey=$CIStatus;HVCIWMI=$MIStatus;HVCIEnabled=$IntegrityStatus;CredGuard=$CredStatus;DomainUsr=$DomainUsr"
Write-Output $Output

# Define código de saída
If ($CIStatus -ne "OK" -or $MIStatus -ne "OK") {
    Exit 1
} else {
    Exit 0
}
