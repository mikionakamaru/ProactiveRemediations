if (
    (Test-Path "C:\Program Files\WinRAR\WinRAR.exe") -or
    (Test-Path "C:\Program Files (x86)\WinRAR\WinRAR.exe")
) {
    Write-Output "WinRAR instalado"
    exit 1
}

Write-Output "WinRAR nao encontrado"
exit 0
