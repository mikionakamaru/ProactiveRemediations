# Remediation Script for Intune
try {
    # Atualiza a assinatura do antivírus
    Update-MpSignature -Verbose | Out-Null

    Write-Output "Remediation completed successfully."
    exit 0
} catch {
    Write-Output "Remediation failed."
    exit 1
}
