# Manual de instalación y uso

Guía paso a paso para poner en marcha el monitor proactivo con tu GLPI 11: primero en **un equipo de prueba**, y después en el resto.

**Tiempo estimado:** 15 min en GLPI + 10 min en el primer equipo + 15 min de pruebas.

| Necesitas | Para |
|---|---|
| Usuario **Super-Admin** en GLPI 11 | Crear el usuario técnico y los tokens (solo la primera vez) |
| Un **PC Windows de prueba** con permisos de administrador | Instalar el agente (mejor uno tuyo, no el de un usuario) |
| GLPI accesible por **HTTPS** desde ese PC | Los tokens viajan en cabeceras; el agente se niega a usar HTTP salvo `localhost` |
| *(Opcional)* un servidor Linux | Probar también el agente Linux |

> Los nombres de menú y de casillas están tal cual aparecen en GLPI 11.0.13 en español (comprobados en una instalación real). Ojo: según la pantalla, los tickets se llaman **Peticiones** o **Solicitudes**, y los equipos **Ordenadores** o **Computadoras**.

---

## Parte 1 · Preparar GLPI (una sola vez)

### 1.1 Activar la API

**Configuración > General > pestaña API**

| Opción | Valor |
|---|---|
| Habilitar la API REST heredada (Legacy) | **Sí** |
| Habilitar acceso con credenciales | **No** |
| Habilitar acceso con token externo | **Sí** |

Activa primero **Habilitar la API REST heredada (Legacy)** y pulsa **Guardar**: las otras dos opciones y la lista de **Clientes API** solo aparecen después. GLPI mostrará un aviso naranja recomendando la API nueva; es normal. El interruptor **Habilitar API** (la API nueva) no lo usa el monitor: si nada más la necesita, apágalo.

### 1.2 Crear el cliente API (App-Token)

En la misma pestaña, sección **Clientes API (API heredada / Legacy)** → **Añadir cliente API**:

- **Nombre:** `Monitor proactivo`
- **Activo:** Sí
- **Intervalo de direcciones IPv4:** el rango de tu red interna (por ejemplo `192.168.1.1` – `192.168.1.254`). Para la prueba puedes poner solo la IP del PC de prueba.
- **Token de aplicación:** marca **Regenerar** y guarda.

👉 Vuelve a abrir el cliente y copia el **Token de aplicación**. Es el **App-Token**.

> Si el agente va a estar **en el propio servidor de GLPI**, no crees un cliente: usa *full access from localhost* (ver Parte 7.3).

### 1.3 Crear el perfil de mínimo privilegio

**Administración > Perfiles > Añadir**

- **Nombre:** `API Monitor`
- **Interfaz del perfil:** **Interfaz estándar**
- **Perfil predeterminado:** sin marcar

> ⚠️ Comprueba la interfaz en la pestaña **Perfil**. Si queda en *Interfaz simplificada*, el perfil **no muestra** las pestañas *Activos* ni *Gestión* y no podrás dar los permisos de equipos y documentos.

Guarda, abre el perfil y marca **solo** estas casillas (columna exacta de GLPI 11), pulsando **Guardar** en cada pestaña:

| Pestaña | Fila | Columnas a marcar |
|---|---|---|
| Soporte | Solicitudes | **Ver mis peticiones** y **Crear** |
| Soporte | Followups | **Ver los públicos** y **Agregar (solicitante)** |
| Gestión | Documentos | **Ver todo** y **Crear** |
| Activos | Ordenadores | **Ver todo** |

> ⚠️ **"Leer notas" no es "Lectura".** Solo da acceso a las notas del objeto, no al objeto. La columna de lectura en GLPI 11 se llama **Ver todo**. No marques tampoco *Ver asignados* ni *Ver propios*. En *Soporte* deja vacía la sección **Asociación**.

¿Por qué tan poco? Si alguien robase el token de un PC, con este perfil solo podría abrir tickets. No puede ver tickets de otros, cerrar nada, borrar nada ni tocar el inventario.

### 1.4 Crear el usuario técnico (User-Token)

**Administración > Usuarios > Añadir**

- **Usuario:** `svc-glpi-monitor`
- **Contraseña:** una larga y aleatoria (no se usa nunca)
- Abajo del formulario: **Perfil** `API Monitor`, **Entidad** la raíz, **Recursivo: Sí** → **Añadir**.
- Entra en el usuario:
  - **Perfil predeterminado:** `API Monitor`.
  - Revisa que el navegador **no haya autorrellenado** campos (por ejemplo *Teléfono 2* con `glpi`, o la contraseña con la del administrador). Si es así, bórralos y usa **Cambiar contraseña**.
  - Apartado **Contraseñas y claves de acceso > API token**: marca **Regenerar** y **Guardar**. Después copia el token con el icono del portapapeles.
  - Pestaña **Autorizaciones**: debe haber **una sola línea**: tu entidad → `API Monitor (R)`. La **(R)** es *Recursivo*. Si aparece *Self-Service*, bórrala.

👉 Copia el **API token**. Es el **User-Token**.

### 1.5 (Recomendado) Grupo y origen

- Anota el **ID del grupo** al que quieres que lleguen los tickets (por ejemplo *Sistemas N2*). El ID es el número del final de la URL cuando abres el grupo: `.../group.form.php?id=`**`3`**.
- *(Opcional)* En **Configuración > Desplegables > Orígenes de la petición** crea `Monitorización automática` y anota su ID. Así podrás sacar estadísticas de cuántos tickets se detectaron antes de que llamara nadie.

### 1.6 Comprobar que el PC de prueba está en el inventario

Busca el nombre del PC en **Activos > Ordenadores**. Si lo inventaría el agente de GLPI, ya estará. El nombre tiene que coincidir con el nombre del equipo en Windows (`hostname`). Si no está, el ticket se crea igualmente pero sin vincular al equipo.

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
| `Equipo no vinculable: sin permiso para leer equipos` | Falta el permiso de lectura de ordenadores (a menudo se marca *Leer notas* por error) | Perfiles > API Monitor > Activos > Ordenadores > **Ver todo** |
| `ERROR_RIGHT_MISSING` o HTTP 403 | Falta un permiso en el perfil, o el perfil no está en la entidad | Revisa la tabla de la Parte 1.3 y que sea **recursivo** |
| `API disabled` | API apagada | Parte 1.1 |
| `Equipo '...' no encontrado en el inventario` | El nombre en GLPI no coincide | Corrige el nombre en GLPI o pon `"ComputerName": "NOMBRE-EN-GLPI"` en el config |
| `No se pudieron descifrar los tokens` | Copiaste el `config.json` de otro PC | Ejecuta el instalador en este PC |
| `No se puede cargar el archivo ... ejecución de scripts deshabilitada` | Política de ejecución | `Set-ExecutionPolicy -Scope Process Bypass -Force` en esa ventana |
| `Ya hay otra ejecución en curso` | La tarea estaba corriendo | Espera unos segundos y repite |

Si algo no encaja, el log (`C:\ProgramData\GlpiMonitor\GlpiMonitor.log`) siempre dice qué ha pasado.

---

## Parte 7 · Linux (y el propio servidor GLPI)

### 7.1 Subir el proyecto al servidor

La consola de VirtualBox no permite pegar: trabaja por **SSH** desde Windows (`ssh usuario@IP`; para pegar, clic derecho). Para subir el ZIP, desde **otra** ventana de PowerShell **en Windows** (no dentro del SSH):

```powershell
scp "C:\Users\TU_USUARIO\Downloads\GLPI-Proactive-Monitor-main.zip" usuario@IP_DEL_SERVIDOR:~
```

### 7.2 Instalar

En el SSH:

```bash
sudo apt update && sudo apt install -y curl jq unzip      # RHEL/Rocky: dnf install -y curl jq unzip
unzip -o GLPI-Proactive-Monitor-main.zip && cd GLPI-Proactive-Monitor-main/linux
sudo ./install.sh
sudo nano /etc/glpi-monitor/glpi-monitor.conf              # guardar: Ctrl+O, Enter · salir: Ctrl+X
```

El timer arranca al instalar: si la primera ejecución ocurre antes de editar el fichero, deja un error en el log. Es normal.

### 7.3 Caso especial: el agente en el propio servidor de GLPI

Si el servidor que vigilas **es el de GLPI**, usa `localhost`. Ventajas: funciona aunque GLPI aún no tenga HTTPS, y no cambia nada si la máquina cambia de IP (por ejemplo al migrarla de VirtualBox a ESXi).

- En GLPI, en vez de crear un cliente API nuevo, regenera el **Token de aplicación** del cliente **full access from localhost** (rango `127.0.0.1`): ese token solo sirve desde el propio servidor.
- En el `.conf`:

```bash
GLPI_URL="http://localhost/apirest.php"     # http, no https, mientras no haya certificado
GLPI_APP_TOKEN="<App-Token>"
GLPI_USER_TOKEN="<User-Token>"
COMPUTER_NAME="cpg"                         # sin la # delante; igual que en Activos > Ordenadores
SERVICES="apache2 mariadb cron"
AUTO_RESTART_SERVICES=true
```

> **Por qué `AUTO_RESTART_SERVICES=true` aquí:** si Apache o MariaDB caen, GLPI no puede recibir el ticket. Con el reinicio automático el agente levanta el servicio y **entonces** abre el ticket *"caído — reiniciado automáticamente"*. Si el reinicio fallara, solo quedaría en el log local: es el límite de vigilar un servidor desde sí mismo.

En otros servidores Linux, usa la URL HTTPS de GLPI y pon en `SERVICES` lo que importe en cada uno (por ejemplo `"ssh cron nginx"`).

### 7.4 Pruebas

```bash
sudo glpi-monitor --test                  # tres ✔: sesión, equipo encontrado, sesión cerrada
sudo glpi-monitor --dry-run               # todo OK si el servidor está sano
sudo glpi-monitor --simulate all          # 4 tickets [SIMULACRO] con adjunto
sudo glpi-monitor --simulate all          # otra vez: no debe crear ninguno ("sigue abierto")
sudo glpi-monitor                         # los 4 reciben "Recuperado automáticamente"
```

Fallo real, sin riesgo:

```bash
sudo systemctl stop cron
sudo glpi-monitor                         # lo arranca solo y abre "Servicio cron caído — reiniciado automáticamente"
systemctl is-active cron                  # active
sudo glpi-monitor                         # seguimiento de recuperado en ese ticket
```

Servicio automático y log:

```bash
systemctl list-timers glpi-monitor.timer  # próxima ejecución (cada hora)
tail -f /var/log/glpi-monitor.log
```

---

## Parte 8 · Copias de seguridad del servidor GLPI

El script `backup/glpi-backup.sh` hace cada noche la copia que pide el SOP: base de datos **y** ficheros (adjuntos y configuración, incluida `glpicrypt.key`). El monitor vigila que se genere: si un día falta, abre un ticket.

### 8.1 Instalar

En el SSH del servidor GLPI, desde la carpeta del proyecto:

```bash
cd ~/GLPI-Proactive-Monitor-main/backup
sudo ./install.sh
sudo systemctl start glpi-backup                 # primera copia, ahora
journalctl -u glpi-backup -n 20 --no-pager       # debe terminar con "Copia terminada correctamente"
sudo ls -lh /var/backups/glpi
```

Se generan dos ficheros por noche (a las 02:30) y se borran los de más de 14 días:

| Fichero | Contiene |
|---|---|
| `glpi-db_AAAAMMDD-HHMM.sql.gz` | La base de datos completa (tickets, usuarios, perfiles, formularios, reglas...) |
| `glpi-files_AAAAMMDD-HHMM.tar.gz` | `config/` (con **glpicrypt.key**), `files/` (adjuntos), `marketplace/` y `plugins/` |

> ⚠️ **Sin `glpicrypt.key` la copia no sirve del todo**: GLPI no podría descifrar los tokens de la API ni las contraseñas guardadas (correo, LDAP). Por eso va siempre incluida y los ficheros quedan con permisos `600`, solo legibles por root.

Con MariaDB de Ubuntu no hace falta configurar nada: root entra por socket. Los ajustes (días a conservar, rutas, copia a un NAS) están en `/etc/glpi-backup.conf`.

### 8.2 Que el monitor la vigile

En `/etc/glpi-monitor/glpi-monitor.conf`:

```bash
BACKUP_CHECKS=(
  "Volcado BD GLPI|/var/backups/glpi/glpi-db_*.sql.gz|26"
  "Adjuntos y config GLPI|/var/backups/glpi/glpi-files_*.tar.gz|26"
)
```

Comprueba con `sudo glpi-monitor --dry-run`: deben salir dos líneas `OK Copia ... de hace 0 h`. Si una noche falla la copia, a la mañana siguiente tendrás el ticket.

### 8.3 Sacar las copias del servidor

Una copia en el mismo disco no te salva si se pierde la VM o el datastore. Opciones:

- **NAS:** monta una carpeta compartida (por ejemplo en `/mnt/nas/glpi`) y ponla en `OFFSITE_DIR` de `/etc/glpi-backup.conf`. El script copia ahí cada copia y también la rota.
- **Manual (mínimo):** de vez en cuando, desde Windows: `scp angel@IP:/var/backups/glpi/* D:\CopiasGLPI\` (como root, o copia antes los ficheros a tu usuario).

### 8.4 Restaurar (también sirve para migrar a otro servidor)

1. Servidor nuevo con Ubuntu 24.04 y el **apartado 4 del SOP**: LAMP, base `glpi`, usuario `glpi@localhost` y GLPI 11.0.13 descomprimido en `/var/www/glpi`. **No** pases el asistente web.
2. Copia los dos ficheros al servidor nuevo y:

```bash
sudo tar -xzf glpi-files_AAAAMMDD-HHMM.tar.gz -C /                 # recoloca config/, files/, marketplace/, plugins/
zcat glpi-db_AAAAMMDD-HHMM.sql.gz | sudo mariadb glpi               # carga la base de datos
sudo chown -R www-data:www-data /var/www/glpi/{config,files,marketplace,plugins}
sudo -u www-data php /var/www/glpi/bin/console cache:clear
sudo systemctl restart apache2
```

3. Si la contraseña del usuario `glpi@localhost` de MariaDB es distinta en el servidor nuevo, actualízala en `/var/www/glpi/config/config_db.php` (o con `sudo -u www-data php /var/www/glpi/bin/console db:configure`).
4. Comprueba: entras con tus usuarios, abres un ticket con adjunto y lo descargas, y `sudo glpi-monitor --test` da los tres ✔ (eso confirma que `glpicrypt.key` se ha restaurado: los tokens siguen funcionando).

> Haz esta prueba de restauración al menos una vez (el SOP la pide en 10.3). Una copia que nunca se ha restaurado es una suposición, no una copia.

---

## Parte 9 · Desplegarlo en más equipos

1. **Una semana con 3-5 equipos** de distintos tipos. Ajusta servicios y umbrales: aquí aparecen los falsos positivos.
2. **El resto**, con la herramienta de despliegue que uses (Intune, PDQ, SCCM, o PowerShell remoto):

   ```powershell
   .\Install-GlpiMonitor.ps1 -GlpiUrl https://glpi.tuempresa.local/apirest.php -AppToken '...' -UserToken '...'
   ```

   Pon tu `config.json` ya ajustado como `config.example.json` antes de desplegar, o pásalo con `-ConfigTemplate`.

> ⚠️ **No lo despliegues con un script de inicio de GPO que lleve los tokens.** La carpeta SYSVOL la puede leer cualquier usuario del dominio y los tokens quedarían expuestos.

3. **Mide el resultado** en GLPI: filtra por el origen *Monitorización automática* y compáralo con los tickets que entran por teléfono o correo. Ese número es lo que enseñas en una entrevista.
