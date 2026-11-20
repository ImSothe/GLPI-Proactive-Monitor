#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instala (o desinstala) GlpiMonitor en un equipo Windows.

.DESCRIPTION
    1. Copia GlpiMonitor.ps1 a C:\ProgramData\GlpiMonitor.
    2. Restringe la carpeta a SYSTEM y Administradores (los tokens viven ahí).
    3. Guarda los tokens de GLPI cifrados con DPAPI (ámbito máquina): el config
       copiado a otro equipo no sirve.
    4. Registra una tarea programada como SYSTEM, cada N minutos con retardo
       aleatorio para no saturar GLPI.
    5. Prueba la conexión con GLPI.

    Si no pasas los tokens como parámetro se piden de forma oculta, para que no
    queden en el historial de PowerShell.

.EXAMPLE
    .\Install-GlpiMonitor.ps1 -GlpiUrl https://glpi.example.local/apirest.php

.EXAMPLE
    .\Install-GlpiMonitor.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)][string]$GlpiUrl,
    [Parameter(ParameterSetName = 'Install')][string]$AppToken,
    [Parameter(ParameterSetName = 'Install')][string]$UserToken,
    [Parameter(ParameterSetName = 'Install')][string]$ConfigTemplate = (Join-Path $PSScriptRoot 'config.example.json'),
    [Parameter(ParameterSetName = 'Install')][ValidateRange(15, 1440)][int]$IntervalMinutes = 60,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)][switch]$Uninstall,
    [string]$InstallDir = (Join-Path $env:ProgramData 'GlpiMonitor')
)
$ErrorActionPreference = 'Stop'
$taskName = 'GLPI Proactive Monitor'
$taskPath = '\GlpiMonitor\'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "GlpiMonitor desinstalado (tarea y $InstallDir eliminados)."
    return
}

function Read-Secret([string]$Prompt) {
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Protect-Secret([string]$Plain) {
    Add-Type -AssemblyName System.Security
    $bytes = [System.Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($Plain), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return 'dpapi:' + [Convert]::ToBase64String($bytes)
}

if ($GlpiUrl -notmatch '^https://') { throw 'GlpiUrl debe usar HTTPS (los tokens viajan en cabeceras).' }

# --- 1. Carpeta con permisos restringidos ------------------------------------
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
# SIDs en lugar de nombres: funciona igual en Windows en español ("Administradores")
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls falló al proteger $InstallDir" }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'GlpiMonitor.ps1') -Destination $InstallDir -Force

# --- 2. Configuración (se conserva la existente al actualizar) ----------------
$configPath = Join-Path $InstallDir 'config.json'
$source = if (Test-Path -LiteralPath $configPath) { $configPath } else { $ConfigTemplate }
$config = Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json
$config.Glpi.Url = $GlpiUrl

$hasTokens = $config.Glpi.AppToken -like 'dpapi:*' -and $config.Glpi.UserToken -like 'dpapi:*'
if ($AppToken -or $UserToken -or -not $hasTokens) {
    if (-not $AppToken) { $AppToken = Read-Secret 'App-Token de GLPI' }
    if (-not $UserToken) { $UserToken = Read-Secret 'User-Token de svc-glpi-monitor' }
    $config.Glpi.AppToken = Protect-Secret $AppToken
    $config.Glpi.UserToken = Protect-Secret $UserToken
    $AppToken = $null; $UserToken = $null
}
$json = $config | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($configPath, $json, (New-Object Text.UTF8Encoding $false))

# --- 3. Tarea programada como SYSTEM -----------------------------------------
$script = Join-Path $InstallDir 'GlpiMonitor.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RandomDelay (New-TimeSpan -Minutes 10)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable `
    -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force `
    -Description 'Comprueba disco, servicios, reinicios y copias; abre tickets proactivos en GLPI.' | Out-Null

Write-Host "Instalado en $InstallDir. Tarea '$taskPath$taskName' cada $IntervalMinutes min." -ForegroundColor Green

# --- 4. Prueba de conexión ---------------------------------------------------
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -TestConnection
Write-Host "`nSiguiente paso recomendado:  & '$script' -Simulate all   (crea tickets de prueba en GLPI)"
