try {
    # Obtém a data atual
    $CurrentDate = (Get-Date).Date

    # Obtém a data da assinatura do antivírus
    $SignatureDate = (Get-MpComputerStatus).AntivirusSignatureLastUpdated.Date

    # Compara as datas
    if ($SignatureDate -eq $CurrentDate) {
        # Retorna "Compliant" com a data da assinatura
        Write-Output "Compliant: Signature Date is $SignatureDate"
        exit 0
    } else {
        # Retorna "NonCompliant" com a data da assinatura
        Write-Output "NonCompliant: Signature Date is $SignatureDate"
        exit 1
    }
} catch {
    # Caso ocorra erro, retorna "NonCompliant" com a mensagem de falha
    Write-Output "NonCompliant: Detection failed"
    exit 1
}
