# Manual de instalación y uso

Guía paso a paso para poner en marcha el monitor proactivo con tu GLPI 11: primero en **un equipo de prueba**, y después en el resto.

**Tiempo estimado:** 15 min en GLPI + 10 min en el primer equipo + 15 min de pruebas.

| Necesitas | Para |
|---|---|
| Usuario **Super-Admin** en GLPI 11 | Crear el usuario técnico y los tokens (solo la primera vez) |
| Un **PC Windows de prueba** con permisos de administrador | Instalar el agente (mejor uno tuyo, no el de un usuario) |
| GLPI accesible por **HTTPS** desde ese PC | Los tokens viajan en cabeceras; el agente se niega a usar HTTP salvo `localhost` |
| *(Opcional)* un servidor Linux | Probar también el agente Linux |

> Los nombres de menú están tal cual aparecen en GLPI 11 en español. Ojo: en la traducción de GLPI los tickets se llaman **Peticiones** y los equipos **Computadoras**.

---

## Parte 1 · Preparar GLPI (una sola vez)

### 1.1 Activar la API

**Configuración > General > pestaña API**

| Opción | Valor |
|---|---|
| Habilitar la API REST heredada (Legacy) | **Sí** |
| Habilitar acceso con credenciales | **No** |
| Habilitar acceso con token externo | **Sí** |

Guarda.

### 1.2 Crear el cliente API (App-Token)

En la misma pestaña, sección de **clientes API** → **Añadir**:

- **Nombre:** `Monitor proactivo`
- **Activo:** Sí
- **Intervalo de direcciones IPv4:** el rango de tu red interna (por ejemplo `192.168.1.1` – `192.168.1.254`). Para la prueba puedes poner solo la IP del PC de prueba.
- **Token de aplicación:** marca **Regenerar** y guarda.

👉 Copia el **Token de aplicación** en un bloc de notas. Es el **App-Token**.

### 1.3 Crear el perfil de mínimo privilegio

**Administración > Perfiles > Añadir**

- **Nombre:** `API Monitor`
- **Interfaz:** Interfaz estándar

Guarda, abre el perfil y marca **solo** esto (todo lo demás vacío):

| Pestaña | Objeto | Marcar |
|---|---|---|
| Soporte | Peticiones (tickets) | **Crear** y **Ver mis tickets** |
| Soporte | Seguimientos | **Ver los públicos** y **Añadir a mis tickets** |
| Gestión | Documento | **Lectura** y **Crear** |
| Activos | Computadora | **Lectura** |

¿Por qué tan poco? Si alguien robase el token de un PC, con este perfil solo podría abrir tickets. No puede ver tickets de otros, cerrar nada, borrar nada ni tocar el inventario.

### 1.4 Crear el usuario técnico (User-Token)

**Administración > Usuarios > Añadir**

- **Usuario:** `svc-glpi-monitor`
- **Contraseña:** una larga y aleatoria (no se usa nunca)
- Guarda y entra en el usuario:
  - Pestaña de **habilitaciones/perfiles**: añade el perfil `API Monitor` en la entidad raíz, **Recursivo: Sí**. Si tiene otro perfil por defecto (Self-Service), quítaselo.
  - En la ficha del usuario, apartado **API token**: marca **Regenerar** y guarda.

👉 Copia el **API token**. Es el **User-Token**.

### 1.5 (Recomendado) Grupo y origen

- Anota el **ID del grupo** al que quieres que lleguen los tickets (por ejemplo *Sistemas N2*). El ID es el número del final de la URL cuando abres el grupo: `.../group.form.php?id=`**`3`**.
- *(Opcional)* En **Configuración > Desplegables > Orígenes de la petición** crea `Monitorización automática` y anota su ID. Así podrás sacar estadísticas de cuántos tickets se detectaron antes de que llamara nadie.

### 1.6 Comprobar que el PC de prueba está en el inventario

Busca el nombre del PC en **Activos > Computadoras**. Si lo inventaría el agente de GLPI, ya estará. El nombre tiene que coincidir con el nombre del equipo en Windows (`hostname`). Si no está, el ticket se crea igualmente pero sin vincular al equipo.

---

## Parte 2 · Instalar en el PC Windows de prueba

### 2.1 Descargar el proyecto

Como el repositorio es privado: entra en GitHub con tu cuenta → repositorio **GLPI-Proactive-Monitor** → **Code > Download ZIP**. Descomprímelo, por ejemplo en `C:\Temp\GLPI-Proactive-Monitor`.

### 2.2 Ejecutar el instalador

Abre **PowerShell como administrador** (clic derecho → *Ejecutar como administrador*) y pega, cambiando la URL por la tuya:

```powershell
cd C:\Temp\GLPI-Proactive-Monitor\windows
Get-ChildItem -Recurse | Unblock-File
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-GlpiMonitor.ps1 -GlpiUrl https://glpi.tuempresa.local/apirest.php
```

Te pedirá los dos tokens (no se ven al escribir; pega con clic derecho y pulsa Enter):

1. **App-Token de GLPI** → el de la Parte 1.2
2. **User-Token de svc-glpi-monitor** → el de la Parte 1.4

Al terminar hace una prueba de conexión. Lo que debes ver:

```text
Instalado en C:\ProgramData\GlpiMonitor. Tarea '\GlpiMonitor\GLPI Proactive Monitor' cada 60 min.
Probando conexión con https://glpi.tuempresa.local/apirest.php ...
  OK  Sesión iniciada (App-Token y User-Token válidos)
  OK  Equipo 'PC-SOTHE' encontrado en el inventario (Computer #57)
  OK  Sesión cerrada
```

Si sale un error, mira la [Parte 6](#parte-6--problemas-frecuentes).

### 2.3 Ajustar la configuración

Abre el fichero (como administrador):

```powershell
notepad C:\ProgramData\GlpiMonitor\config.json
```

Lo mínimo que conviene tocar:

```json
"Glpi": {
  ...
  "GroupsIdAssign": 3,          <- ID del grupo de la Parte 1.5 (o null)
  "RequestTypesId": null        <- ID del origen "Monitorización automática" (o null)
},
"Services": {
  "Names": ["Spooler", "EventLog", "Dnscache"],   <- servicios críticos de ESTE equipo
  "AutoRestart": false
},
```

- **No toques** `AppToken` ni `UserToken`: están cifrados para este equipo concreto.
- Usa el **nombre corto** del servicio (columna *Nombre* en `services.msc` o `Get-Service`), no el nombre para mostrar.
- Las copias de seguridad vienen desactivadas (`"Enabled": false`). Las configuras cuando el resto funcione (ver [Parte 5](#parte-5--copias-de-seguridad)).

---

## Parte 3 · Probarlo (plan de prueba)

En la misma ventana de PowerShell como administrador:

```powershell
$m = 'C:\ProgramData\GlpiMonitor\GlpiMonitor.ps1'
```

### Prueba 1 · Ver qué detecta, sin enviar nada

```powershell
& $m -DryRun
```

Hace las comprobaciones reales y muestra lo que **haría**. No toca GLPI. Si todo está sano verás solo líneas `OK`.

### Prueba 2 · Simulacro: tickets de prueba en GLPI

```powershell
& $m -Simulate all
```

Crea **4 tickets** marcados `[SIMULACRO]`. Ve a GLPI y comprueba en cada uno:

- [ ] Título `[Monitor] NOMBRE-PC · [SIMULACRO] ...`
- [ ] El equipo aparece vinculado (pestaña *Elementos*)
- [ ] Está asignado a tu grupo (si pusiste `GroupsIdAssign`)
- [ ] Tiene adjunto un `diag_....txt`: ábrelo y mira el diagnóstico

Ejecuta el simulacro **otra vez**: no debe crear ninguno nuevo (el log dirá *"sigue abierto... sin acción"*).

Luego una ejecución normal:

```powershell
& $m
```

Los 4 tickets reciben el seguimiento **"✔ Recuperado automáticamente"**. Ya puedes resolverlos.

### Prueba 3 · Un fallo de verdad (servicio)

La cola de impresión es segura de parar en un PC de prueba:

```powershell
Stop-Service Spooler
& $m                      # -> crea el ticket "Servicio crítico Spooler detenido (Stopped)"
Start-Service Spooler
& $m                      # -> añade "Recuperado automáticamente" a ese ticket
```

### Prueba 4 · Un fallo de verdad (disco)

Sin llenar el disco: sube el umbral temporalmente para que salte.

1. En `config.json` pon `"FreePercentMin": 99`.
2. `& $m` → ticket *"Disco C: casi lleno"* con el diagnóstico de carpetas temporales.
3. Vuelve a poner `"FreePercentMin": 10`.
4. `& $m` → seguimiento de recuperado.

### Prueba 5 · La tarea programada

```powershell
Start-ScheduledTask -TaskPath '\GlpiMonitor\' -TaskName 'GLPI Proactive Monitor'
Start-Sleep 20
Get-Content C:\ProgramData\GlpiMonitor\GlpiMonitor.log -Tail 5
```

Debe aparecer una ejecución nueva en el log (esta vez lanzada como SYSTEM, igual que lo hará cada hora).

✅ Si pasan las 5 pruebas, el monitor funciona en tu entorno.

---

## Parte 4 · Uso diario

**No hay que hacer nada:** la tarea se ejecuta cada hora (con un retardo aleatorio de hasta 10 min) y solo contacta con GLPI cuando hay algo que contar.

| Quiero... | Cómo |
|---|---|
| Ver qué ha hecho | `Get-Content C:\ProgramData\GlpiMonitor\GlpiMonitor.log -Tail 30` |
| Ejecutarlo ya | `Start-ScheduledTask -TaskPath '\GlpiMonitor\' -TaskName 'GLPI Proactive Monitor'` |
| Ver qué detectaría ahora | `& $m -DryRun` |
| Cambiar umbrales o servicios | Editar `config.json`; se aplica en la siguiente ejecución |
| Ver los tickets que tiene abiertos | `Get-Content C:\ProgramData\GlpiMonitor\state.json` |
| Cambiar los tokens | Volver a ejecutar el instalador con `-AppToken` / `-UserToken` (o sin ellos y te los pide si no hay) |
| Actualizar el script | Volver a ejecutar el instalador: conserva tu `config.json` |
| Desinstalar | `.\Install-GlpiMonitor.ps1 -Uninstall` |

**Cómo se comporta con los tickets:**

- Un problema = un ticket. No se repite cada hora.
- Si sigue fallando 24 h después, añade un seguimiento con diagnóstico nuevo.
- Cuando se arregla solo, añade "Recuperado automáticamente". **No cierra el ticket**: eso lo decide el técnico.
- Si el técnico resuelve el ticket y el fallo vuelve, abre uno nuevo (es una recurrencia).
- Como máximo crea 5 tickets por ejecución.

**Qué umbrales trae por defecto:** disco < 10 % (urgencia alta) o < 5 % (muy alta) · reinicio pendiente más de 14 días · copia con más de 26 h.

---

## Parte 5 · Copias de seguridad

En `config.json`, dentro de `"Backups"`, pon `"Enabled": true` en el tipo que uses y rellénalo:

**A) Tu copia deja ficheros en una carpeta o NAS** (lo más habitual):

```json
{ "Name": "Copia diaria NAS", "Enabled": true, "Type": "File",
  "Path": "\\\\nas01\\backups\\%COMPUTERNAME%\\*.vhdx", "MaxAgeHours": 26 }
```

Avisa si el fichero más reciente tiene más de 26 h o pesa 0 bytes. En JSON cada `\` se escribe `\\`.

> La tarea corre como SYSTEM, que en la red se identifica como **la cuenta del equipo** (`DOMINIO\NOMBREPC$`). Dale permiso de lectura en la carpeta compartida o el chequeo dirá *acceso denegado*.

**B) Windows Server Backup** (servidores):

```json
{ "Name": "Windows Server Backup", "Enabled": true, "Type": "WindowsServerBackup", "MaxAgeHours": 26 }
```

**C) Cualquier software que escriba un evento al terminar bien** (Veeam, Cobian, etc.):

```json
{ "Name": "Veeam Agent", "Enabled": true, "Type": "EventLog",
  "LogName": "Application", "ProviderName": "Veeam Agent", "EventId": 190, "MaxAgeHours": 26 }
```

Los valores de `LogName`, `ProviderName` y `EventId` son **un ejemplo**: búscalos en el Visor de eventos tras una copia correcta de tu software.

Comprueba la configuración con `& $m -DryRun`.

---

## Parte 6 · Problemas frecuentes

| Mensaje | Qué pasa | Solución |
|---|---|---|
| `GlpiUrl debe usar HTTPS` | Tu GLPI va por HTTP | Activa HTTPS en GLPI (los tokens viajarían en claro). Mientras tanto, pruébalo en el laboratorio (`lab/`) |
| `ERROR_WRONG_APP_TOKEN_PARAMETER` | App-Token mal copiado | Reinstala pegando el token de la Parte 1.2 |
| `ERROR_NOT_ALLOWED_IP` | La IP del PC no está en el rango del cliente API | Amplía el intervalo IPv4 en la Parte 1.2 |
| `ERROR_GLPI_LOGIN_USER_TOKEN` | User-Token mal copiado o regenerado | Reinstala con el token actual de `svc-glpi-monitor` |
| `ERROR_RIGHT_MISSING` o HTTP 403 | Falta un permiso en el perfil, o el perfil no está en la entidad | Revisa la tabla de la Parte 1.3 y que sea **recursivo** |
| `API disabled` | API apagada | Parte 1.1 |
| `Equipo '...' no encontrado en el inventario` | El nombre en GLPI no coincide | Corrige el nombre en GLPI o pon `"ComputerName": "NOMBRE-EN-GLPI"` en el config |
| `No se pudieron descifrar los tokens` | Copiaste el `config.json` de otro PC | Ejecuta el instalador en este PC |
| `No se puede cargar el archivo ... ejecución de scripts deshabilitada` | Política de ejecución | `Set-ExecutionPolicy -Scope Process Bypass -Force` en esa ventana |
| `Ya hay otra ejecución en curso` | La tarea estaba corriendo | Espera unos segundos y repite |

Si algo no encaja, el log (`C:\ProgramData\GlpiMonitor\GlpiMonitor.log`) siempre dice qué ha pasado.

---

## Parte 7 · Linux (opcional)

En el servidor, como root:

```bash
sudo apt install -y curl jq              # en RHEL/Rocky: dnf install -y curl jq
cd GLPI-Proactive-Monitor/linux
sudo ./install.sh
sudo nano /etc/glpi-monitor/glpi-monitor.conf
```

Rellena `GLPI_URL`, `GLPI_APP_TOKEN`, `GLPI_USER_TOKEN`, `GROUPS_ID_ASSIGN` y `SERVICES` (por ejemplo `"ssh cron nginx"`). Después las mismas pruebas:

```bash
sudo glpi-monitor --test
sudo glpi-monitor --dry-run
sudo glpi-monitor --simulate all
sudo glpi-monitor                         # cierra el simulacro
systemctl list-timers glpi-monitor.timer  # próxima ejecución
tail -f /var/log/glpi-monitor.log
```

---

## Parte 8 · Desplegarlo en más equipos

1. **Una semana con 3-5 equipos** de distintos tipos. Ajusta servicios y umbrales: aquí aparecen los falsos positivos.
2. **El resto**, con la herramienta de despliegue que uses (Intune, PDQ, SCCM, o PowerShell remoto):

   ```powershell
   .\Install-GlpiMonitor.ps1 -GlpiUrl https://glpi.tuempresa.local/apirest.php -AppToken '...' -UserToken '...'
   ```

   Pon tu `config.json` ya ajustado como `config.example.json` antes de desplegar, o pásalo con `-ConfigTemplate`.

> ⚠️ **No lo despliegues con un script de inicio de GPO que lleve los tokens.** La carpeta SYSVOL la puede leer cualquier usuario del dominio y los tokens quedarían expuestos.

3. **Mide el resultado** en GLPI: filtra por el origen *Monitorización automática* y compáralo con los tickets que entran por teléfono o correo. Ese número es lo que enseñas en una entrevista.
