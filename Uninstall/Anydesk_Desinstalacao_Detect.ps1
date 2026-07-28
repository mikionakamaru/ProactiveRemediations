$AnyDesk = Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like '*AnyDesk*' }

if ($AnyDesk) {
    Write-Output 'OK - AnyDesk instalado'
    exit 1
}

Write-Output 'NOK - AnyDesk nao encontrado'
exit 0
