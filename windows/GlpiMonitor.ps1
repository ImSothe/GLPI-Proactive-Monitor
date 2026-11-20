<#
.SYNOPSIS
    Monitor proactivo de salud para Windows con apertura automática de tickets en GLPI.

.DESCRIPTION
    Comprueba disco, servicios críticos, reinicios pendientes y copias de seguridad.
    Si detecta un fallo abre un ticket en GLPI (API REST) con el diagnóstico adjunto,
    antes de que el usuario llame.

      - Sin duplicados: un ticket por problema mientras siga abierto.
      - Seguimiento periódico si el problema persiste y aviso al recuperarse.
      - Sin tráfico hacia GLPI si todo está bien.

    Compatible con Windows PowerShell 5.1 y PowerShell 7+. Pensado para ejecutarse
    como SYSTEM desde una tarea programada (ver Install-GlpiMonitor.ps1).

.PARAMETER ConfigPath
    Ruta al config.json. Por defecto: C:\ProgramData\GlpiMonitor\config.json

.PARAMETER DryRun
    Ejecuta las comprobaciones y muestra lo que haría, sin llamar a GLPI.

.PARAMETER TestConnection
    Solo prueba la conexión con GLPI y la búsqueda del equipo en el inventario.

.PARAMETER Simulate
    Simulacro: genera fallos ficticios (all, disk, service, reboot, backup) para
    validar la integración con GLPI sin romper nada.

.EXAMPLE
    .\GlpiMonitor.ps1 -TestConnection
    .\GlpiMonitor.ps1 -DryRun
    .\GlpiMonitor.ps1 -Simulate all

.NOTES
    Códigos de salida: 0 = todo OK · 1 = hay fallos (tickets gestionados) · 2 = error de configuración/API
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun,
    [switch]$TestConnection,
    [ValidateSet('all', 'disk', 'service', 'reboot', 'backup')]
    [string[]]$Simulate
)

$ErrorActionPreference = 'Continue'
$script:Version = '1.0.0'
if (-not $ConfigPath) { $ConfigPath = Join-Path $env:ProgramData 'GlpiMonitor\config.json' }

# ============================================================== utilidades ==
function Write-MonitorLog {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (-not $DryRun -and $script:LogFile) {
        try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
        catch { Write-Verbose "No se pudo escribir en el log: $($_.Exception.Message)" }
    }
}

function Get-Setting {
    # Lee una ruta tipo 'Disk.FreePercentMin' del config, con valor por defecto
    param([object]$Object, [string]$Path, $Default)
    $cur = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $Default }
        $prop = $cur.PSObject.Properties[$part]
        if ($null -eq $prop) { return $Default }
        $cur = $prop.Value
    }
    if ($null -eq $cur -or ($cur -is [string] -and $cur -eq '')) { return $Default }
    return $cur   # los llamadores envuelven con @() cuando esperan una lista
}

function Unprotect-Secret {
    # Los tokens pueden guardarse cifrados con DPAPI (ámbito máquina): "dpapi:BASE64"
    param([string]$Value)
    if ($Value -and $Value.StartsWith('dpapi:')) {
        Add-Type -AssemblyName System.Security
        $bytes = [Convert]::FromBase64String($Value.Substring(6))
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        return [Text.Encoding]::UTF8.GetString($plain)
    }
    return $Value
}

function Format-ByteSize([double]$Bytes) {
    $units = 'B', 'KB', 'MB', 'GB', 'TB'; $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes /= 1024; $i++ }
    return ('{0:N1} {1}' -f $Bytes, $units[$i])
}

function ConvertTo-HtmlEncoded([string]$Text) { return [System.Net.WebUtility]::HtmlEncode($Text) }
function Get-Now { return (Get-Date).ToString('o') }
function ConvertFrom-IsoDate([string]$Value) {
    return [datetime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
}

# ================================================================== estado ==
# state.json = { checks: { "<clave>": {ticket_id, opened, last_followup, title} },
#                meta:   { RebootPendingSince: "<iso>" } }
function Read-State {
    $s = @{ checks = @{}; meta = @{} }
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $j = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.checks) {
                foreach ($p in $j.checks.PSObject.Properties) {
                    $s.checks[$p.Name] = @{
                        ticket_id     = [int]$p.Value.ticket_id
                        opened        = [string]$p.Value.opened
                        last_followup = [string]$p.Value.last_followup
                        title         = [string]$p.Value.title
                    }
                }
            }
            if ($j.meta) { foreach ($p in $j.meta.PSObject.Properties) { $s.meta[$p.Name] = [string]$p.Value } }
        } catch { Write-MonitorLog WARN "state.json ilegible, se regenera: $($_.Exception.Message)" }
    }
    return $s
}

function Save-State {
    if ($DryRun) { return }
    $json = ConvertTo-Json -InputObject $script:State -Depth 5
    [IO.File]::WriteAllText($script:StateFile, $json, (New-Object Text.UTF8Encoding $false))
}

# ============================================================== resultados ==
$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Key, [ValidateSet('OK', 'FAIL')][string]$Status, [int]$Urgency = 0,
        [string]$Title = '', [string]$Detail = '', [string]$Action = '', [string]$Evidence = '')
    $script:Results.Add([pscustomobject]@{
            Key = $Key; Status = $Status; Urgency = $Urgency; Title = $Title
            Detail = $Detail; Action = $Action; Evidence = $Evidence
        })
}

# ---------------------------------------------------------------- 1) DISCO --
function Test-Disk {
    if (-not (Get-Setting $script:Config 'Disk.Enabled' $true)) { return }
    $min = [double](Get-Setting $script:Config 'Disk.FreePercentMin' 10)
    $crit = [double](Get-Setting $script:Config 'Disk.FreePercentCritical' 5)
    $exclude = @(Get-Setting $script:Config 'Disk.ExcludeDrives' @()) | ForEach-Object { "$_".TrimEnd('\').ToUpper() }

    $disks = Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop
    foreach ($d in $disks) {
        if (-not $d.Size -or ($exclude -contains $d.DeviceID.ToUpper())) { continue }
        $free = [math]::Round($d.FreeSpace * 100 / $d.Size, 1)
        $key = "disk:$($d.DeviceID)"
        if ($free -lt $min) {
            $urg = if ($free -lt $crit) { 5 } else { 4 }
            Add-Result -Key $key -Status FAIL -Urgency $urg `
                -Title ('Disco {0} casi lleno ({1}% libre)' -f $d.DeviceID, $free) `
                -Detail ('Unidad {0} ({1}): {2}% libre — {3} libres de {4}. Umbral: {5}% (crítico: {6}%).' -f `
                    $d.DeviceID, $d.VolumeName, $free, (Format-ByteSize $d.FreeSpace), (Format-ByteSize $d.Size), $min, $crit) `
                -Action 'Revisar en el adjunto las carpetas temporales/caché que más ocupan. Liberar con el Liberador de espacio (cleanmgr), vaciar SoftwareDistribution\Download y perfiles antiguos, o ampliar el volumen.' `
                -Evidence $key
        } else {
            Add-Result -Key $key -Status OK -Detail ('Disco {0}: {1}% libre' -f $d.DeviceID, $free)
        }
    }
}

# ------------------------------------------------------------ 2) SERVICIOS --
function Test-Service {
    $names = @(Get-Setting $script:Config 'Services.Names' @())
    if ($names.Count -eq 0) { return }
    $autoRestart = [bool](Get-Setting $script:Config 'Services.AutoRestart' $false)

    foreach ($n in $names) {
        $key = "service:$n"
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) {
            Add-Result -Key $key -Status FAIL -Urgency 4 -Title "Servicio crítico $n no existe" `
                -Detail "El servicio '$n' está configurado como crítico pero no existe en el equipo." `
                -Action 'Verificar si se ha desinstalado o renombrado, o corregir la configuración del monitor.' -Evidence $key
            continue
        }
        if ($svc.Status -eq 'Running') {
            Add-Result -Key $key -Status OK -Detail "Servicio $n en ejecución"
            continue
        }
        $previous = $svc.Status
        $startType = $svc.StartType
        if ($autoRestart -and -not $DryRun -and $startType -ne 'Disabled') {
            Write-MonitorLog INFO "Servicio $n en estado '$previous': intento de arranque automático"
            try {
                Start-Service -Name $n -ErrorAction Stop
                $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            } catch { Write-MonitorLog WARN "No se pudo arrancar $($n): $($_.Exception.Message)" }
            $svc.Refresh()
            if ($svc.Status -eq 'Running') {
                Add-Result -Key $key -Status FAIL -Urgency 2 -Title "Servicio $n caído — arrancado automáticamente" `
                    -Detail "El servicio '$($svc.DisplayName)' estaba en estado '$previous'. El monitor lo arrancó y ahora está en ejecución. Se abre ticket para analizar la causa raíz." `
                    -Action 'Revisar en el adjunto los eventos del Service Control Manager para averiguar por qué se detuvo. Si se repite, abrir un Problema.' -Evidence $key
                continue
            }
        }
        $extra = if ($startType -eq 'Disabled') { ' El servicio está DESHABILITADO.' } elseif ($autoRestart) { ' El arranque automático ha fallado.' } else { '' }
        Add-Result -Key $key -Status FAIL -Urgency 4 -Title "Servicio crítico $n detenido ($previous)" `
            -Detail "El servicio '$($svc.DisplayName)' ($n) está en estado '$previous' (inicio: $startType).$extra" `
            -Action "Revisar los eventos del servicio en el adjunto (credenciales de la cuenta de servicio, dependencias, puertos) y arrancarlo: Start-Service $n" -Evidence $key
    }
}

# --------------------------------------------------- 3) REINICIO PENDIENTE --
function Get-PendingRebootReason {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons += 'Component Based Servicing (instalación de componentes/parches)'
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons += 'Windows Update'
    }
    try {
        $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
        $pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
        if ($active -ne $pendingName) { $reasons += "Cambio de nombre pendiente ($active -> $pendingName)" }
    } catch { Write-Verbose "No se pudo leer el nombre de equipo pendiente: $($_.Exception.Message)" }
    # PendingFileRenameOperations da muchos falsos positivos (antivirus, instaladores): opcional
    if (Get-Setting $script:Config 'Reboot.IncludeFileRenameOperations' $false) {
        $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfro) { $reasons += 'PendingFileRenameOperations' }
    }
    return , $reasons
}

function Test-PendingReboot {
    if (-not (Get-Setting $script:Config 'Reboot.Enabled' $true)) { return }
    $maxDays = [int](Get-Setting $script:Config 'Reboot.PendingMaxDays' 14)
    $maxUptime = [int](Get-Setting $script:Config 'Reboot.MaxUptimeDays' 0)

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $uptimeDays = [int][math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)
    $reasons = Get-PendingRebootReason

    if ($reasons.Count -gt 0) {
        # ¿Desde cuándo? Lo más antiguo entre lo que ya teníamos registrado y el primer
        # parche instalado después del último arranque (útil en la primera ejecución).
        $since = Get-Date
        if ($script:State.meta.ContainsKey('RebootPendingSince')) {
            $since = ConvertFrom-IsoDate $script:State.meta['RebootPendingSince']
        }
        $firstPatch = Get-HotFix -ErrorAction SilentlyContinue |
            Where-Object { $_.InstalledOn -and $_.InstalledOn -ge $os.LastBootUpTime.Date } |
            Sort-Object InstalledOn | Select-Object -First 1
        if ($firstPatch -and $firstPatch.InstalledOn -lt $since) { $since = $firstPatch.InstalledOn }
        $script:State.meta['RebootPendingSince'] = $since.ToString('o')

        $days = [int][math]::Floor(((Get-Date) - $since).TotalDays)
        if ($days -ge $maxDays) {
            Add-Result -Key 'reboot' -Status FAIL -Urgency 3 -Title "Reinicio pendiente desde hace $days días" `
                -Detail ("El equipo necesita reiniciarse desde hace $days días (umbral: $maxDays). Motivo: {0}. Último arranque: {1:dd/MM/yyyy HH:mm} ($uptimeDays días)." -f ($reasons -join '; '), $os.LastBootUpTime) `
                -Action 'Planificar el reinicio con el usuario o en ventana de mantenimiento: los parches de seguridad no están activos hasta reiniciar.' -Evidence 'reboot'
            return
        }
    } else {
        [void]$script:State.meta.Remove('RebootPendingSince')
    }

    if ($maxUptime -gt 0 -and $uptimeDays -ge $maxUptime) {
        Add-Result -Key 'reboot' -Status FAIL -Urgency 3 -Title "Equipo sin reiniciar desde hace $uptimeDays días" `
            -Detail ("Último arranque: {0:dd/MM/yyyy HH:mm} (máximo configurado: $maxUptime días)." -f $os.LastBootUpTime) `
            -Action 'Planificar reinicio con el usuario o en ventana de mantenimiento.' -Evidence 'reboot'
    } else {
        Add-Result -Key 'reboot' -Status OK -Detail 'Sin reinicio pendiente fuera de plazo'
    }
}

# ------------------------------------------------- 4) COPIAS DE SEGURIDAD --
function Test-Backup {
    foreach ($b in @(Get-Setting $script:Config 'Backups' @())) {
        if ($null -eq $b -or -not (Get-Setting $b 'Enabled' $true)) { continue }
        $name = Get-Setting $b 'Name' 'Copia'
        $type = Get-Setting $b 'Type' 'File'
        $maxH = [double](Get-Setting $b 'MaxAgeHours' 26)
        $key = "backup:$name"
        $evid = "backup:$name"
        try {
            switch ($type) {
                'File' {
                    $path = [Environment]::ExpandEnvironmentVariables((Get-Setting $b 'Path' ''))
                    if (-not $path) { throw "Falta 'Path' en la configuración de la copia" }
                    $f = Get-ChildItem -Path $path -File -Force -ErrorAction Stop |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if (-not $f) { throw "No hay ningún fichero que cumpla '$path'" }
                    $age = [math]::Round(((Get-Date) - $f.LastWriteTime).TotalHours, 1)
                    if ($f.Length -eq 0) {
                        Add-Result -Key $key -Status FAIL -Urgency 4 -Title "Copia '$name' vacía (0 bytes)" `
                            -Detail "La última copia ($($f.FullName)) tiene 0 bytes." `
                            -Action 'Revisar el log del trabajo de copia: probablemente falló a mitad.' -Evidence $evid
                    } elseif ($age -gt $maxH) {
                        Add-Result -Key $key -Status FAIL -Urgency 4 -Title "Copia '$name' desactualizada ($age h)" `
                            -Detail "La última copia tiene $age horas (máximo: $maxH h): $($f.FullName)" `
                            -Action 'Comprobar el planificador del trabajo de copia y su último log.' -Evidence $evid
                    } else {
                        Add-Result -Key $key -Status OK -Detail "Copia '$name' de hace $age h"
                    }
                }
                'WindowsServerBackup' {
                    $wb = Get-WBSummary -ErrorAction Stop
                    $last = $wb.LastSuccessfulBackupTime
                    $age = if ($last -and $last.Year -gt 2000) { [math]::Round(((Get-Date) - $last).TotalHours, 1) } else { [double]::MaxValue }
                    if ($wb.LastBackupResultHR -ne 0 -or $age -gt $maxH) {
                        $ageText = if ($age -eq [double]::MaxValue) { 'nunca' } else { "hace $age h" }
                        Add-Result -Key $key -Status FAIL -Urgency 4 -Title "Windows Server Backup '$name' con fallos" `
                            -Detail ("Última copia correcta: $ageText (máximo: $maxH h). Resultado del último trabajo: 0x{0:X8}." -f $wb.LastBackupResultHR) `
                            -Action 'Revisar Get-WBJob -Previous 3 y el visor de eventos (Microsoft-Windows-Backup). Comprobar el destino de la copia.' -Evidence $evid
                    } else {
                        Add-Result -Key $key -Status OK -Detail "Windows Server Backup '$name' correcto ($age h)"
                    }
                }
                'EventLog' {
                    # Busca el evento de "copia correcta" de tu software de backup en las últimas N horas
                    $filter = @{ LogName = (Get-Setting $b 'LogName' 'Application'); Id = [int](Get-Setting $b 'EventId' 0)
                        StartTime = (Get-Date).AddHours(-$maxH) }
                    $prov = Get-Setting $b 'ProviderName' $null
                    if ($prov) { $filter['ProviderName'] = $prov }
                    $ev = Get-WinEvent -FilterHashtable $filter -MaxEvents 1 -ErrorAction SilentlyContinue
                    if (-not $ev) {
                        Add-Result -Key $key -Status FAIL -Urgency 4 -Title "Copia '$name' sin éxito en $maxH h" `
                            -Detail "No hay ningún evento de éxito (Id $($filter.Id), $($filter.LogName)) en las últimas $maxH horas." `
                            -Action 'Revisar la consola del software de copias y el último trabajo ejecutado.' -Evidence $evid
                    } else {
                        Add-Result -Key $key -Status OK -Detail "Copia '$name' correcta ($($ev.TimeCreated))"
                    }
                }
                default { throw "Tipo de copia desconocido: $type (usa File, WindowsServerBackup o EventLog)" }
            }
        } catch {
            Add-Result -Key $key -Status FAIL -Urgency 4 -Title "No se puede verificar la copia '$name'" `
                -Detail "Error al comprobar la copia ($type): $($_.Exception.Message)" `
                -Action 'Comprobar que el destino es accesible para la cuenta SYSTEM (cuenta de equipo en recursos de red) y que la copia se está ejecutando.' -Evidence $evid
        }
    }
}

# --------------------------------------------------------------- simulacro --
function Invoke-Simulation {
    $types = if ($Simulate -contains 'all') { 'disk', 'service', 'reboot', 'backup' } else { $Simulate }
    foreach ($t in $types) {
        switch ($t) {
            'disk' { Add-Result -Key 'sim:disk' -Status FAIL -Urgency 4 -Title '[SIMULACRO] Disco C: casi lleno (4,2% libre)' -Detail 'Fallo ficticio generado con -Simulate para validar la integración con GLPI.' -Action 'Ninguna: es un simulacro. Se cerrará solo en la próxima ejecución normal.' -Evidence 'disk:C:' }
            'service' { Add-Result -Key 'sim:service' -Status FAIL -Urgency 4 -Title '[SIMULACRO] Servicio crítico detenido' -Detail 'Fallo ficticio generado con -Simulate.' -Action 'Ninguna: es un simulacro.' -Evidence 'summary' }
            'reboot' { Add-Result -Key 'sim:reboot' -Status FAIL -Urgency 3 -Title '[SIMULACRO] Reinicio pendiente desde hace 21 días' -Detail 'Fallo ficticio generado con -Simulate.' -Action 'Ninguna: es un simulacro.' -Evidence 'reboot' }
            'backup' { Add-Result -Key 'sim:backup' -Status FAIL -Urgency 4 -Title '[SIMULACRO] Copia de seguridad desactualizada (49 h)' -Detail 'Fallo ficticio generado con -Simulate.' -Action 'Ninguna: es un simulacro.' -Evidence 'summary' }
        }
    }
}

# ============================================================== evidencias ==
function Add-Section {
    param([System.Text.StringBuilder]$Sb, [string]$SectionTitle, [scriptblock]$Block)
    [void]$Sb.AppendLine()
    [void]$Sb.AppendLine("===== $SectionTitle =====")
    try {
        $sectionOut = & $Block 2>&1 | Out-String -Width 220
        [void]$Sb.AppendLine($sectionOut.TrimEnd())
    } catch {
        [void]$Sb.AppendLine("(no disponible: $($_.Exception.Message))")
    }
}

function Get-FolderSize([string]$FolderPath) {
    $sum = (Get-ChildItem -Path $FolderPath -Recurse -Force -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    return [double]$sum
}

function New-EvidenceFile {
    param([object]$Check)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Diagnóstico generado por GlpiMonitor $script:Version")
    [void]$sb.AppendLine("Equipo:  $script:ComputerName")
    [void]$sb.AppendLine("Fecha:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    [void]$sb.AppendLine("Motivo:  $($Check.Key) — $($Check.Title)")

    Add-Section $sb 'Resumen del equipo' {
        $cs = Get-CimInstance Win32_ComputerSystem
        $os = Get-CimInstance Win32_OperatingSystem
        $ips = (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True').IPAddress -join ', '
        [pscustomobject]@{
            Equipo          = $cs.Name; Dominio = $cs.Domain; Modelo = "$($cs.Manufacturer) $($cs.Model)"
            SistemaOperativo = "$($os.Caption) $($os.Version)"; UltimoArranque = $os.LastBootUpTime
            UsuarioActivo   = $cs.UserName; IPs = $ips
            RAM             = '{0} libres de {1}' -f (Format-ByteSize ($os.FreePhysicalMemory * 1KB)), (Format-ByteSize $cs.TotalPhysicalMemory)
        } | Format-List
    }
    Add-Section $sb 'Discos' {
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Select-Object DeviceID, VolumeName,
            @{n = 'Tamaño'; e = { Format-ByteSize $_.Size } }, @{n = 'Libre'; e = { Format-ByteSize $_.FreeSpace } },
            @{n = '% Libre'; e = { [math]::Round($_.FreeSpace * 100 / $_.Size, 1) } } | Format-Table -AutoSize
    }

    $spec = $Check.Evidence
    if ($spec -like 'disk:*') {
        $driveLetter = $spec.Substring(5)
        Add-Section $sb "Carpetas típicas de basura en $driveLetter" {
            $candidates = @('Windows\Temp', 'Windows\SoftwareDistribution\Download', '$Recycle.Bin',
                'Windows\Logs\CBS', 'ProgramData\Microsoft\Windows\WER', 'Windows\Minidump')
            $rows = foreach ($c in $candidates) {
                $full = Join-Path "$driveLetter\" $c
                if (Test-Path -LiteralPath $full) { [pscustomobject]@{ Carpeta = $full; Tamaño = Get-FolderSize $full } }
            }
            $rows += Get-ChildItem -Path "$driveLetter\Users\*\AppData\Local\Temp" -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object { [pscustomobject]@{ Carpeta = $_.FullName; Tamaño = Get-FolderSize $_.FullName } }
            $rows | Sort-Object Tamaño -Descending |
                Select-Object Carpeta, @{n = 'Tamaño'; e = { Format-ByteSize $_.Tamaño } } | Format-Table -AutoSize
        }
        Add-Section $sb "Perfiles de usuario en $driveLetter" {
            Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -like "$driveLetter*" } |
                Select-Object LocalPath, LastUseTime | Sort-Object LastUseTime | Format-Table -AutoSize
        }
    } elseif ($spec -like 'service:*') {
        $svcName = $spec.Substring(8)
        Add-Section $sb "Configuración del servicio $svcName" {
            Get-CimInstance Win32_Service -Filter "Name='$($svcName -replace "'", "''")'" |
                Select-Object Name, DisplayName, State, StartMode, StartName, ExitCode, ServiceSpecificExitCode, PathName | Format-List
        }
        Add-Section $sb "Eventos del Service Control Manager (7 días) relacionados con $svcName" {
            $display = (Get-Service -Name $svcName -ErrorAction SilentlyContinue).DisplayName
            if (-not $display) { $display = $svcName }
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager'
                Id = 7000, 7001, 7009, 7011, 7022, 7023, 7024, 7031, 7034; StartTime = (Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue |
                Where-Object { $_.Message -match [regex]::Escape($display) -or $_.Message -match [regex]::Escape($svcName) } |
                Select-Object -First 30 TimeCreated, Id, Message | Format-List
        }
    } elseif ($spec -eq 'reboot') {
        Add-Section $sb 'Motivos de reinicio pendiente' { Get-PendingRebootReason }
        Add-Section $sb 'Últimos parches instalados' {
            Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10 HotFixID, Description, InstalledOn | Format-Table -AutoSize
        }
        Add-Section $sb 'Eventos de Windows Update (30 días)' {
            Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'
                StartTime = (Get-Date).AddDays(-30) } -MaxEvents 15 -ErrorAction SilentlyContinue |
                Select-Object TimeCreated, Id, Message | Format-List
        }
    } elseif ($spec -like 'backup:*') {
        $bkName = $spec.Substring(7)
        $bk = @(Get-Setting $script:Config 'Backups' @()) | Where-Object { $_.Name -eq $bkName } | Select-Object -First 1
        if ($bk) {
            $bkType = Get-Setting $bk 'Type' 'File'
            if ($bkType -eq 'File') {
                Add-Section $sb "Contenido del destino de copia" {
                    Get-ChildItem -Path (Split-Path -Path ([Environment]::ExpandEnvironmentVariables($bk.Path)) -Parent) -Force -ErrorAction Stop |
                        Sort-Object LastWriteTime -Descending | Select-Object -First 20 Mode, LastWriteTime, Length, Name | Format-Table -AutoSize
                }
            } elseif ($bkType -eq 'WindowsServerBackup') {
                Add-Section $sb 'Resumen Windows Server Backup' { Get-WBSummary | Format-List }
                Add-Section $sb 'Últimos trabajos' { Get-WBJob -Previous 3 | Format-List }
            } elseif ($bkType -eq 'EventLog') {
                Add-Section $sb "Últimos eventos de $($bk.LogName)" {
                    Get-WinEvent -LogName $bk.LogName -MaxEvents 20 -ErrorAction Stop | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List
                }
            }
        }
    }

    Add-Section $sb 'Servicios automáticos detenidos' {
        Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" |
            Select-Object Name, DisplayName, State, ExitCode | Format-Table -AutoSize
    }
    Add-Section $sb 'Errores críticos del registro System (24 h)' {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddHours(-24) } -MaxEvents 40 -ErrorAction SilentlyContinue |
            Select-Object TimeCreated, Id, ProviderName, @{n = 'Mensaje'; e = { ($_.Message -split "`r?`n")[0] } } | Format-Table -AutoSize -Wrap
    }

    $safeKey = ($Check.Key -replace '[^A-Za-z0-9_-]', '_').Trim('_')
    $file = Join-Path $script:WorkDir ('diag_{0}_{1}_{2}.txt' -f $script:ComputerName, $safeKey, (Get-Date -Format 'yyyyMMdd-HHmm'))
    [IO.File]::WriteAllText($file, $sb.ToString(), (New-Object Text.UTF8Encoding $false))
    return $file
}

# ================================================================ API GLPI ==
function Initialize-Http {
    Add-Type -AssemblyName System.Net.Http
    # Windows PowerShell 5.1 no activa TLS 1.2 por defecto
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:Http = New-Object System.Net.Http.HttpClient
    $script:Http.Timeout = [TimeSpan]::FromSeconds(30)
}

function Invoke-GlpiApi {
    param([string]$Method, [string]$Path, [object]$Json, [System.Net.Http.HttpContent]$Content, [switch]$InitSession)
    $uri = "$($script:BaseUrl)/$Path"
    $attempts = if ($Method -eq 'GET') { 3 } else { 1 }   # no se reintentan POST: evitaría tickets duplicados
    for ($n = 1; $n -le $attempts; $n++) {
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::new($Method)), $uri
        [void]$req.Headers.TryAddWithoutValidation('App-Token', $script:AppToken)
        if ($InitSession) {
            [void]$req.Headers.TryAddWithoutValidation('Authorization', "user_token $($script:UserToken)")
        } elseif ($script:SessionToken) {
            [void]$req.Headers.TryAddWithoutValidation('Session-Token', $script:SessionToken)
        }
        if ($null -ne $Json) {
            $body = ConvertTo-Json -InputObject $Json -Depth 10 -Compress
            $req.Content = New-Object System.Net.Http.StringContent ($body, [Text.Encoding]::UTF8, 'application/json')
        } elseif ($Content) {
            $req.Content = $Content
        }
        try {
            $resp = $script:Http.SendAsync($req).GetAwaiter().GetResult()
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $data = $null
            if ($text) { try { $data = ConvertFrom-Json -InputObject $text } catch { $data = $text } }
            $result = [pscustomobject]@{ Code = [int]$resp.StatusCode; Ok = $resp.IsSuccessStatusCode; Data = $data; Raw = "$text" }
            if ($result.Ok -or $result.Code -lt 500 -or $n -eq $attempts) { return $result }
        } catch {
            if ($n -eq $attempts) {
                return [pscustomobject]@{ Code = 0; Ok = $false; Data = $null; Raw = $_.Exception.GetBaseException().Message }
            }
        }
        Start-Sleep -Seconds 3
    }
}

function Get-ShortText([string]$Text) { if ($Text.Length -gt 300) { return $Text.Substring(0, 300) } return $Text }

function Connect-Glpi {
    if ($script:SessionToken) { return $true }
    $r = Invoke-GlpiApi -Method GET -Path 'initSession' -InitSession
    if ($r.Ok -and $r.Data.session_token) {
        $script:SessionToken = $r.Data.session_token
        return $true
    }
    Write-MonitorLog ERROR "No se pudo iniciar sesión en GLPI (HTTP $($r.Code)): $(Get-ShortText $r.Raw)"
    return $false
}

function Disconnect-Glpi {
    if ($script:SessionToken) { [void](Invoke-GlpiApi -Method GET -Path 'killSession'); $script:SessionToken = $null }
}

function Find-Computer {
    if ($script:ComputerId) { return }
    $q = 'Computer?searchText%5Bname%5D={0}&range=0-49' -f [uri]::EscapeDataString($script:ComputerName)
    $r = Invoke-GlpiApi -Method GET -Path $q
    if (-not $r.Ok) {
        # Distinguir "no tengo permiso" de "no existe": el primero se arregla en el perfil
        if ($r.Raw -match 'ERROR_RIGHT_MISSING') {
            $script:ComputerError = "sin permiso para leer equipos (ERROR_RIGHT_MISSING). En GLPI: Perfiles > API Monitor > Activos > Ordenadores > 'Ver todo'"
        } else {
            $script:ComputerError = "la búsqueda del equipo falló (HTTP $($r.Code)): $(Get-ShortText $r.Raw)"
        }
        Write-MonitorLog WARN "No se puede vincular el ticket al equipo: $script:ComputerError"
        return
    }
    $match = @($r.Data) | Where-Object { $_.name -eq $script:ComputerName } | Select-Object -First 1
    if ($match) { $script:ComputerId = [int]$match.id; return }
    $script:ComputerError = "no existe ningún equipo llamado '$script:ComputerName' (revisa Activos > Ordenadores o ComputerName en config.json)"
    Write-MonitorLog WARN "Equipo '$script:ComputerName' no encontrado en el inventario de GLPI: el ticket no irá vinculado"
}

function Get-TicketStatus([int]$TicketId) {
    # Devuelve 1-6, 'gone' si ya no existe, o $null si no se pudo consultar
    $r = Invoke-GlpiApi -Method GET -Path "Ticket/$TicketId"
    if ($r.Ok) { return [int]$r.Data.status }
    if ($r.Code -eq 404 -or $r.Code -eq 400) { return 'gone' }
    return $null
}

function Send-Document([int]$TicketId, [string]$FilePath, [string]$DisplayName) {
    $fileName = [IO.Path]::GetFileName($FilePath)
    $manifest = ConvertTo-Json -Compress -Depth 5 -InputObject @{
        input = @{ name = $DisplayName; _filename = @($fileName); itemtype = 'Ticket'; items_id = $TicketId }
    }
    $mp = New-Object System.Net.Http.MultipartFormDataContent
    $part = New-Object System.Net.Http.StringContent ($manifest, [Text.Encoding]::UTF8, 'application/json')
    $part.Headers.ContentDisposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue 'form-data'
    $part.Headers.ContentDisposition.Name = '"uploadManifest"'
    $mp.Add($part)
    $filePart = New-Object System.Net.Http.ByteArrayContent (, [IO.File]::ReadAllBytes($FilePath))
    $filePart.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue 'text/plain'
    $filePart.Headers.ContentDisposition = New-Object System.Net.Http.Headers.ContentDispositionHeaderValue 'form-data'
    $filePart.Headers.ContentDisposition.Name = '"filename[0]"'
    $filePart.Headers.ContentDisposition.FileName = '"' + $fileName + '"'
    $mp.Add($filePart)

    $r = Invoke-GlpiApi -Method POST -Path 'Document' -Content $mp
    if ($r.Ok) { Write-MonitorLog INFO "Diagnóstico adjuntado al ticket #$TicketId (documento #$($r.Data.id))" }
    else { Write-MonitorLog WARN "No se pudo adjuntar el diagnóstico al ticket #$TicketId (HTTP $($r.Code)): $(Get-ShortText $r.Raw)" }
    Remove-Item -LiteralPath $FilePath -Force -ErrorAction SilentlyContinue
}

function Add-Followup([int]$TicketId, [string]$Html) {
    $r = Invoke-GlpiApi -Method POST -Path 'ITILFollowup' -Json @{ input = @{ itemtype = 'Ticket'; items_id = $TicketId; content = $Html } }
    if (-not $r.Ok) { Write-MonitorLog WARN "No se pudo añadir seguimiento al ticket #$TicketId (HTTP $($r.Code))" }
}

function Get-TicketHtml([object]$Check) {
    $os = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { [Environment]::OSVersion.VersionString }
    $ip = try {
        @((Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop).IPAddress |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0]
    } catch { '' }
    return @"
<p><strong>Alerta proactiva</strong> detectada automáticamente por <em>GlpiMonitor</em>, antes de que el usuario lo notifique.</p>
<table border="1" cellpadding="4" cellspacing="0">
<tr><td style="white-space:nowrap"><strong>Equipo</strong></td><td>$(ConvertTo-HtmlEncoded $script:ComputerName) ($(ConvertTo-HtmlEncoded $ip))</td></tr>
<tr><td style="white-space:nowrap"><strong>Sistema</strong></td><td>$(ConvertTo-HtmlEncoded $os)</td></tr>
<tr><td style="white-space:nowrap"><strong>Comprobación</strong></td><td>$(ConvertTo-HtmlEncoded $Check.Key)</td></tr>
<tr><td style="white-space:nowrap"><strong>Detalle</strong></td><td>$(ConvertTo-HtmlEncoded $Check.Detail)</td></tr>
<tr><td style="white-space:nowrap"><strong>Detectado</strong></td><td>$(Get-Date -Format 'dd/MM/yyyy HH:mm')</td></tr>
</table>
<p><strong>Acción sugerida:</strong> $(ConvertTo-HtmlEncoded $Check.Action)</p>
<p>Se adjunta el diagnóstico completo del equipo. <small>GlpiMonitor $script:Version (Windows)</small></p>
"@
}

function New-GlpiTicket([object]$Check) {
    if (-not (Connect-Glpi)) { return $false }
    Find-Computer
    $ticketInput = @{
        name    = "[Monitor] $script:ComputerName · $($Check.Title)"
        content = Get-TicketHtml $Check
        type    = 1          # Incidencia
        urgency = $Check.Urgency
    }
    if ($script:ComputerId) { $ticketInput['items_id'] = @{ Computer = @($script:ComputerId) } }
    foreach ($pair in @(@('EntitiesId', 'entities_id'), @('ItilCategoriesId', 'itilcategories_id'),
            @('RequestTypesId', 'requesttypes_id'), @('GroupsIdAssign', '_groups_id_assign'))) {
        $v = Get-Setting $script:Config "Glpi.$($pair[0])" $null
        if ($null -ne $v) { $ticketInput[$pair[1]] = [int]$v }
    }
    $r = Invoke-GlpiApi -Method POST -Path 'Ticket' -Json @{ input = $ticketInput }
    if (-not $r.Ok -or -not $r.Data.id) {
        Write-MonitorLog ERROR "No se pudo crear el ticket para $($Check.Key) (HTTP $($r.Code)): $(Get-ShortText $r.Raw)"
        return $false
    }
    $tid = [int]$r.Data.id
    Write-MonitorLog INFO "Ticket #$tid creado: $($Check.Title)"
    Send-Document -TicketId $tid -FilePath (New-EvidenceFile $Check) -DisplayName "Diagnóstico $script:ComputerName · $($Check.Key)"
    $now = Get-Now
    $script:State.checks[$Check.Key] = @{ ticket_id = $tid; opened = $now; last_followup = $now; title = $Check.Title }
    Save-State
    return $true
}

# ============================================================ orquestación ==
function Invoke-FailedCheck([object]$Check) {
    $entry = $script:State.checks[$Check.Key]
    if ($DryRun) {
        if ($entry) { Write-Host "  [dry-run] Ya existe ticket #$($entry.ticket_id) para $($Check.Key) → se comprobaría su estado / seguimiento" }
        else {
            Write-Host "  [dry-run] Se crearía ticket: [Monitor] $script:ComputerName · $($Check.Title) (urgencia $($Check.Urgency))"
            Write-Host "            Detalle: $($Check.Detail)"
            Write-Host "            Acción:  $($Check.Action)"
        }
        return
    }
    if ($entry) {
        if (-not (Connect-Glpi)) { return }
        $tid = $entry.ticket_id
        $st = Get-TicketStatus $tid
        if ($null -eq $st) {
            Write-MonitorLog WARN "No se pudo consultar el ticket #$tid; no se crea otro para evitar duplicados"
            return
        }
        if ($st -ne 'gone' -and $st -lt 5) {
            $hours = [double](Get-Setting $script:Config 'Behaviour.FollowupEveryHours' 24)
            $last = if ($entry.last_followup) { ConvertFrom-IsoDate $entry.last_followup } else { [datetime]::MinValue }
            if (((Get-Date) - $last).TotalHours -ge $hours) {
                Add-Followup $tid "<p><strong>El problema continúa.</strong> $(ConvertTo-HtmlEncoded $Check.Detail)</p><p>Se adjunta diagnóstico actualizado.</p>"
                Send-Document -TicketId $tid -FilePath (New-EvidenceFile $Check) -DisplayName "Diagnóstico actualizado $script:ComputerName · $($Check.Key)"
                $entry.last_followup = Get-Now
                Save-State
                Write-MonitorLog INFO "Ticket #$tid sigue abierto: seguimiento añadido"
            } else {
                Write-MonitorLog INFO "Ticket #$tid sigue abierto para $($Check.Key): sin acción (próximo seguimiento en < $hours h)"
            }
            return
        }
        Write-MonitorLog INFO "El ticket #$tid de $($Check.Key) está resuelto/cerrado pero el problema ha vuelto: se abre uno nuevo"
        [void]$script:State.checks.Remove($Check.Key)
        Save-State
    }
    $max = [int](Get-Setting $script:Config 'Behaviour.MaxTicketsPerRun' 5)
    if ($script:TicketsCreated -ge $max) {
        Write-MonitorLog WARN "Límite de $max tickets por ejecución alcanzado; $($Check.Key) queda para la siguiente"
        return
    }
    if (New-GlpiTicket $Check) { $script:TicketsCreated++ }
}

function Invoke-RecoveredCheck([object]$Check) {
    $entry = $script:State.checks[$Check.Key]
    if (-not $entry) { return }
    if ($DryRun) { Write-Host "  [dry-run] $($Check.Key) recuperado → se añadiría seguimiento al ticket #$($entry.ticket_id)"; return }
    if (Get-Setting $script:Config 'Behaviour.NotifyRecovery' $true) {
        if (-not (Connect-Glpi)) { return }
        $st = Get-TicketStatus $entry.ticket_id
        if ($null -ne $st -and $st -ne 'gone' -and $st -lt 5) {
            Add-Followup $entry.ticket_id ("<p><strong>&#10004; Recuperado automáticamente.</strong> {0} ({1}).</p><p>El técnico puede verificar y resolver el ticket.</p>" -f `
                (ConvertTo-HtmlEncoded $Check.Detail), (Get-Date -Format 'dd/MM/yyyy HH:mm'))
            Write-MonitorLog INFO "$($Check.Key) recuperado: seguimiento añadido al ticket #$($entry.ticket_id)"
        }
    }
    [void]$script:State.checks.Remove($Check.Key)
    Save-State
}

# ==================================================================== main ==
if (-not (Test-Path -LiteralPath $ConfigPath)) { Write-Host "No existe la configuración: $ConfigPath"; exit 2 }
try {
    $script:Config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} catch { Write-Host "Configuración JSON no válida ($ConfigPath): $($_.Exception.Message)"; exit 2 }

$baseDir = Split-Path -Path $ConfigPath -Parent
$script:StateFile = Join-Path $baseDir 'state.json'
$script:LogFile = Join-Path $baseDir 'GlpiMonitor.log'
$script:WorkDir = Join-Path $baseDir 'tmp'
if (-not (Test-Path $script:WorkDir)) { New-Item -ItemType Directory -Path $script:WorkDir -Force | Out-Null }
if ((Test-Path $script:LogFile) -and (Get-Item $script:LogFile).Length -gt 5MB) {
    Move-Item -LiteralPath $script:LogFile -Destination "$($script:LogFile).1" -Force
}

$script:ComputerName = Get-Setting $script:Config 'ComputerName' $env:COMPUTERNAME
if (-not $script:ComputerName) { $script:ComputerName = [Environment]::MachineName }
$script:BaseUrl = ([string](Get-Setting $script:Config 'Glpi.Url' '')).TrimEnd('/')
$script:SessionToken = $null
$script:ComputerId = $null
$script:ComputerError = ''
$script:TicketsCreated = 0

if (-not $DryRun) {
    try {
        $script:AppToken = Unprotect-Secret (Get-Setting $script:Config 'Glpi.AppToken' '')
        $script:UserToken = Unprotect-Secret (Get-Setting $script:Config 'Glpi.UserToken' '')
    } catch { Write-MonitorLog ERROR "No se pudieron descifrar los tokens (¿config copiado de otro equipo?): $($_.Exception.Message)"; exit 2 }
    if (-not $script:BaseUrl -or -not $script:AppToken -or -not $script:UserToken) {
        Write-MonitorLog ERROR 'Faltan Glpi.Url, Glpi.AppToken o Glpi.UserToken en la configuración'; exit 2
    }
    if ($script:BaseUrl -notmatch '^https://') {
        if ($script:BaseUrl -match '^http://(localhost|127\.0\.0\.1)') { Write-MonitorLog WARN 'Usando HTTP sin cifrar (solo aceptable en laboratorio)' }
        else { Write-MonitorLog ERROR 'Glpi.Url debe usar HTTPS: los tokens viajan en cabeceras'; exit 2 }
    }
    Initialize-Http
}

# Evita ejecuciones simultáneas (tarea programada + ejecución manual)
$mutex = New-Object System.Threading.Mutex($false, 'Global\GlpiMonitor')
if (-not $mutex.WaitOne(0)) { Write-MonitorLog WARN 'Ya hay otra ejecución en curso; salgo'; exit 0 }

try {
    $script:State = Read-State

    if ($TestConnection) {
        Write-Host "Probando conexión con $script:BaseUrl ..."
        if (-not (Connect-Glpi)) { exit 2 }
        Write-Host '  OK  Sesión iniciada (App-Token y User-Token válidos)'
        Find-Computer
        if ($script:ComputerId) { Write-Host "  OK  Equipo '$script:ComputerName' encontrado en el inventario (Computer #$script:ComputerId)" }
        else { Write-Host "  !!  Equipo no vinculable: $script:ComputerError. Los tickets se crearán sin vincular" }
        Disconnect-Glpi
        Write-Host '  OK  Sesión cerrada'
        exit 0
    }

    if ($Simulate) {
        Invoke-Simulation
    } else {
        foreach ($checkFn in 'Test-Disk', 'Test-Service', 'Test-PendingReboot', 'Test-Backup') {
            try { & $checkFn } catch { Write-MonitorLog ERROR "Error en la comprobación $($checkFn): $($_.Exception.Message)" }
        }
        # Los simulacros anteriores se dan por recuperados en una ejecución normal
        foreach ($k in @($script:State.checks.Keys)) {
            if ($k -like 'sim:*') { Add-Result -Key $k -Status OK -Detail 'Simulacro finalizado' }
        }
        Save-State   # guarda p. ej. RebootPendingSince aunque no haya tickets
    }

    $fails = 0
    foreach ($res in $script:Results) {
        if ($res.Status -eq 'FAIL') {
            $fails++
            Write-MonitorLog WARN "FALLO $($res.Key): $($res.Title)"
            Invoke-FailedCheck $res
        } else {
            if ($DryRun) { Write-Host "  OK   $($res.Detail)" }
            Invoke-RecoveredCheck $res
        }
    }
    Disconnect-Glpi
    Write-MonitorLog INFO "Ejecución terminada: $($script:Results.Count) comprobaciones, $fails fallos, $script:TicketsCreated tickets nuevos"
    if ($fails -gt 0) { exit 1 } else { exit 0 }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    if ($script:Http) { $script:Http.Dispose() }
}
