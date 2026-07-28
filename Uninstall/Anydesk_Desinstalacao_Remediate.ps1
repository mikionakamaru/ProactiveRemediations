$PossiblePaths = @(
    "C:\Program Files\AnyDesk\AnyDesk.exe",
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
)

$AnyDeskExe = $PossiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($AnyDeskExe) {

    Write-Output "AnyDesk encontrado. Iniciando remocao."

    Stop-Process -Name "AnyDesk" -Force -ErrorAction SilentlyContinue

    Start-Process `
        -FilePath $AnyDeskExe `
        -ArgumentList "--remove --silent" `
        -Wait `
        -NoNewWindow

    Start-Sleep -Seconds 10
}

# Limpeza de diretorios residuais
$Folders = @(
    "C:\Program Files\AnyDesk",
    "C:\Program Files (x86)\AnyDesk",
    "$env:ProgramData\AnyDesk"
)

foreach ($Folder in $Folders) {
    if (Test-Path $Folder) {
        Remove-Item $Folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Limpeza de atalhos (remove apenas se encontrar)
$Shortcuts = @(
    "$env:Public\Desktop\AnyDesk.lnk",
    "$env:USERPROFILE\Desktop\AnyDesk.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AnyDesk.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AnyDesk\AnyDesk.lnk"
)

foreach ($Shortcut in $Shortcuts) {
    if (Test-Path $Shortcut) {
        Write-Output "Removendo atalho: $Shortcut"
        Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue
    }
}

# Remove pasta do atalho no Start Menu se ficou vazia
$StartMenuFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\AnyDesk"
if (Test-Path $StartMenuFolder) {
    Remove-Item $StartMenuFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# Validacao final
$RemainingFiles = @(
    "C:\Program Files\AnyDesk\AnyDesk.exe",
    "C:\Program Files (x86)\AnyDesk\AnyDesk.exe"
) | Where-Object { Test-Path $_ }

if ($RemainingFiles.Count -eq 0) {
    Write-Output "OK - AnyDesk removido completamente."
    exit 0
}
else {
    Write-Output "NOK - Ainda existem arquivos do AnyDesk:"
    $RemainingFiles | ForEach-Object { Write-Output $_ }
    exit 1
}
