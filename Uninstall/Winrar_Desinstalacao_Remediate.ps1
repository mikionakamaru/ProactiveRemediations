$PossiblePaths = @(
    "C:\Program Files\WinRAR",
    "C:\Program Files (x86)\WinRAR"
)

$WinRARFolder = $PossiblePaths | Where-Object { Test-Path (Join-Path $_ "WinRAR.exe") } | Select-Object -First 1

if ($WinRARFolder) {

    Write-Output "WinRAR encontrado. Iniciando remocao."

    # Encerra processos abertos
    Get-Process -Name "WinRAR" -ErrorAction SilentlyContinue | Stop-Process -Force

    # Remove a chave de licenca antes de desinstalar
    $LicenseKey = Join-Path $WinRARFolder "rarreg.key"
    if (Test-Path $LicenseKey) {
        Write-Output "Removendo chave de licenca: $LicenseKey"
        Remove-Item $LicenseKey -Force -ErrorAction SilentlyContinue
    }

    $Uninstaller = Join-Path $WinRARFolder "uninstall.exe"

    if (Test-Path $Uninstaller) {
        Start-Process `
            -FilePath $Uninstaller `
            -ArgumentList "/S" `
            -Wait `
            -NoNewWindow

        Start-Sleep -Seconds 10
    }
    else {
        Write-Output "uninstall.exe nao encontrado na pasta do WinRAR."
    }
}

# ---------------------------------------------------------------------
# Limpeza de diretorios residuais
# ---------------------------------------------------------------------
$Folders = @(
    "C:\Program Files\WinRAR",
    "C:\Program Files (x86)\WinRAR"
)

foreach ($Folder in $Folders) {
    if (Test-Path $Folder) {
        Remove-Item $Folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------
# Limpeza de atalhos: Desktop, Start Menu e Taskbar (todos os perfis)
# ---------------------------------------------------------------------

# Locais de sistema (fora do perfil de usuario)
$SystemShortcuts = @(
    "$env:Public\Desktop\WinRAR.lnk",
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\WinRAR.lnk"
)

foreach ($Shortcut in $SystemShortcuts) {
    if (Test-Path $Shortcut) {
        Write-Output "Removendo atalho: $Shortcut"
        Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue
    }
}

# Pasta do WinRAR no Start Menu (All Users)
$SystemStartFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\WinRAR"
if (Test-Path $SystemStartFolder) {
    Write-Output "Removendo pasta Start Menu (All Users): $SystemStartFolder"
    Remove-Item $SystemStartFolder -Recurse -Force -ErrorAction SilentlyContinue
}

# Varre TODOS os perfis de usuario
Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | ForEach-Object {

    $UserPath = $_.FullName

    # Possiveis Desktops (local + OneDrive redirecionado)
    $DesktopRoots = @(
        (Join-Path $UserPath "Desktop"),
        (Join-Path $UserPath "OneDrive\Desktop")
    )
    # Cobre "OneDrive - Empresa\Desktop" (nome variavel)
    Get-ChildItem $UserPath -Directory -Filter "OneDrive*" -ErrorAction SilentlyContinue | ForEach-Object {
        $DesktopRoots += (Join-Path $_.FullName "Desktop")
    }

    foreach ($Desktop in $DesktopRoots) {
        if (Test-Path $Desktop) {
            Get-ChildItem $Desktop -Filter "WinRAR*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
                Write-Output "Removendo atalho Desktop: $($_.FullName)"
                Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Start Menu por usuario
    $UserStartFolder = Join-Path $UserPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\WinRAR"
    if (Test-Path $UserStartFolder) {
        Write-Output "Removendo pasta Start Menu (usuario): $UserStartFolder"
        Remove-Item $UserStartFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    $UserStartLnk = Join-Path $UserPath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\WinRAR.lnk"
    if (Test-Path $UserStartLnk) {
        Remove-Item $UserStartLnk -Force -ErrorAction SilentlyContinue
    }

    # Taskbar (pin fixado na barra de tarefas)
    $TaskbarFolder = Join-Path $UserPath "AppData\Roaming\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $TaskbarFolder) {
        Get-ChildItem $TaskbarFolder -Filter "WinRAR*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Output "Removendo pin da barra de tarefas: $($_.FullName)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------
# Limpeza de chaves de registro (licenca e configuracoes)
# ---------------------------------------------------------------------
$RegistryKeys = @(
    "HKLM:\SOFTWARE\WinRAR",
    "HKLM:\SOFTWARE\WOW6432Node\WinRAR",
    "HKCU:\SOFTWARE\WinRAR"
)

foreach ($Key in $RegistryKeys) {
    if (Test-Path $Key) {
        Write-Output "Removendo chave de registro: $Key"
        Remove-Item $Key -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Varre HKEY_USERS para limpar HKCU\Software\WinRAR de todos os perfis carregados
$LoadedHives = Get-ChildItem "Registry::HKEY_USERS" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "_Classes$" }

foreach ($Hive in $LoadedHives) {
    $UserWinRARKey = "Registry::$($Hive.Name)\Software\WinRAR"
    if (Test-Path $UserWinRARKey) {
        Remove-Item $UserWinRARKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------
# Validacao final (arquivos + registro)
# ---------------------------------------------------------------------
$RemainingFiles = @(
    "C:\Program Files\WinRAR\WinRAR.exe",
    "C:\Program Files (x86)\WinRAR\WinRAR.exe"
) | Where-Object { Test-Path $_ }

$RemainingKeys = $RegistryKeys | Where-Object { Test-Path $_ }

if ($RemainingFiles.Count -eq 0 -and $RemainingKeys.Count -eq 0) {
    Write-Output "OK - Winrar removido"
    exit 0
}
else {
    Write-Output "NOK - residuos do WinRAR:"
    $RemainingFiles | ForEach-Object { Write-Output "Arquivo: $_" }
    $RemainingKeys  | ForEach-Object { Write-Output "Registro: $_" }
    exit 1
}
