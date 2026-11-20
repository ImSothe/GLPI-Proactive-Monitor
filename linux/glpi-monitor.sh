#!/usr/bin/env bash
# =============================================================================
#  glpi-monitor.sh — Monitor proactivo de salud para Linux
#
#  Comprueba disco, servicios críticos, reinicios pendientes y copias de
#  seguridad. Si algo falla, abre un ticket en GLPI (API REST) con el
#  diagnóstico adjunto ANTES de que el usuario llame.
#
#  - Sin duplicados: un ticket por problema mientras siga abierto.
#  - Seguimiento periódico si el problema persiste y aviso al recuperarse.
#  - Sin tráfico hacia GLPI si todo está bien.
#
#  Requisitos: bash 4+, curl, jq, coreutils (GNU df/stat/find).
#  Uso:        glpi-monitor.sh [-c fichero.conf] [--dry-run|--test|--simulate all]
# =============================================================================
set -uo pipefail
umask 077

VERSION="1.0.0"
CONFIG_FILE="/etc/glpi-monitor/glpi-monitor.conf"
DRY_RUN=false
TEST_ONLY=false
SIMULATE=""

usage() {
  cat <<EOF
glpi-monitor $VERSION — monitor proactivo con tickets automáticos en GLPI

Uso: $(basename "$0") [opciones]
  -c, --config FICHERO   Configuración (por defecto: $CONFIG_FILE)
  -n, --dry-run          Ejecuta las comprobaciones y muestra lo que haría, sin llamar a GLPI
  -t, --test             Solo prueba la conexión con GLPI y la búsqueda del equipo
  -s, --simulate TIPOS   Simulacro: genera fallos ficticios (all | disk,service,reboot,backup)
                         para validar la integración con GLPI sin romper nada
  -h, --help             Muestra esta ayuda

Códigos de salida: 0 = todo OK · 1 = hay fallos (tickets gestionados) · 2 = error de configuración/API
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config)   CONFIG_FILE="${2:?Falta el fichero}"; shift 2 ;;
    -n|--dry-run)  DRY_RUN=true; shift ;;
    -t|--test)     TEST_ONLY=true; shift ;;
    -s|--simulate) SIMULATE="${2:?Indica tipos: all o disk,service,reboot,backup}"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ----------------------------------------------------------------- defaults --
GLPI_URL=""; GLPI_APP_TOKEN=""; GLPI_USER_TOKEN=""; GLPI_CA_BUNDLE=""
COMPUTER_NAME="$(hostname -s 2>/dev/null || hostname)"
ENTITIES_ID=""; ITILCATEGORIES_ID=""; REQUESTTYPES_ID=""; GROUPS_ID_ASSIGN=""
DISK_FREE_PCT_MIN=10
DISK_FREE_PCT_CRITICAL=5
DISK_EXCLUDE_FSTYPES="tmpfs devtmpfs squashfs overlay iso9660 udf efivarfs"
SERVICES=""
AUTO_RESTART_SERVICES=false
REBOOT_PENDING_MAX_DAYS=14
MAX_UPTIME_DAYS=0
BACKUP_CHECKS=()
FOLLOWUP_EVERY_HOURS=24
NOTIFY_RECOVERY=true
MAX_TICKETS_PER_RUN=5
STATE_DIR="/var/lib/glpi-monitor"
LOG_FILE="/var/log/glpi-monitor.log"

log() {
  local msg; msg="$(date '+%F %T') [$1] $2"
  echo "$msg" >&2
  if ! $DRY_RUN; then echo "$msg" >> "$LOG_FILE" 2>/dev/null || true; fi
}
die() { log ERROR "$1"; exit 2; }

for bin in curl jq df stat find; do
  command -v "$bin" >/dev/null 2>&1 || die "Falta la dependencia '$bin'"
done

# ------------------------------------------------- carga segura del config --
[ -r "$CONFIG_FILE" ] || die "No se puede leer la configuración: $CONFIG_FILE"
# El fichero se 'sourcea' (es código) y contiene tokens: no debe poder
# modificarlo nadie salvo su dueño (root o el usuario que ejecuta).
cfg_mode="$(stat -c '%a' "$CONFIG_FILE")"; cfg_owner="$(stat -c '%u' "$CONFIG_FILE")"
if [ "$cfg_owner" != "0" ] && [ "$cfg_owner" != "$(id -u)" ]; then
  die "$CONFIG_FILE debe pertenecer a root (o a quien ejecuta el script)"
fi
(( 8#$cfg_mode & 8#022 )) && die "$CONFIG_FILE es modificable por otros usuarios (permisos $cfg_mode). Usa: chmod 600"
(( 8#$cfg_mode & 8#044 )) && echo "AVISO: $CONFIG_FILE es legible por otros (contiene tokens). Recomendado: chmod 600" >&2
# shellcheck source=/dev/null
. "$CONFIG_FILE"

GLPI_URL="${GLPI_URL%/}"
STATE_FILE="$STATE_DIR/state.json"
WORK_DIR="$STATE_DIR/tmp"
if ! $DRY_RUN; then
  mkdir -p "$STATE_DIR" "$WORK_DIR" || die "No se puede crear $STATE_DIR"
  chmod 700 "$STATE_DIR" "$WORK_DIR"
else
  WORK_DIR="$(mktemp -d)"
fi

if ! $DRY_RUN; then
  [ -n "$GLPI_URL" ] && [ -n "$GLPI_APP_TOKEN" ] && [ -n "$GLPI_USER_TOKEN" ] \
    || die "Faltan GLPI_URL, GLPI_APP_TOKEN o GLPI_USER_TOKEN en $CONFIG_FILE"
  case "$GLPI_URL" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*) log WARN "Usando HTTP sin cifrar (solo aceptable en laboratorio)" ;;
    *) die "GLPI_URL debe usar HTTPS: los tokens viajan en cabeceras" ;;
  esac
fi

# Evita dos ejecuciones simultáneas (p. ej. timer + ejecución manual)
exec 9>"$WORK_DIR/.lock"
flock -n 9 || { log WARN "Ya hay otra ejecución en curso; salgo"; exit 0; }

cleanup() { rm -f "$WORK_DIR"/*.hdr "$WORK_DIR"/*.txt "$WORK_DIR"/*.json 2>/dev/null; $DRY_RUN && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# ------------------------------------------------------------------- estado --
# state.json = { "checks": { "<clave>": {ticket_id, opened, last_followup} },
#                "meta":   { "reboot_pending_since": epoch } }
state_init() {
  if $DRY_RUN; then
    STATE_FILE="$WORK_DIR/state.json"
    cp "$STATE_DIR/state.json" "$STATE_FILE" 2>/dev/null || true
  fi
  if ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    echo '{"checks":{},"meta":{}}' > "$STATE_FILE"
  fi
}
state_q()      { jq -r "$@" "$STATE_FILE"; }
state_update() {  # state_update <filtro jq> [args jq...]
  local filter="$1"; shift
  jq "$@" "$filter" "$STATE_FILE" > "$STATE_FILE.new" && mv "$STATE_FILE.new" "$STATE_FILE"
}
state_get()   { state_q --arg k "$1" --arg f "$2" '.checks[$k][$f] // empty'; }
state_keys()  { state_q '.checks | keys[]'; }
state_del()   { state_update 'del(.checks[$k])' --arg k "$1"; }
meta_get()    { state_q --arg f "$1" '.meta[$f] // empty'; }
meta_set()    { state_update '.meta[$f] = $v' --arg f "$1" --arg v "$2"; }
meta_del()    { state_update 'del(.meta[$f])' --arg f "$1"; }

# --------------------------------------------------------------- resultados --
# Cada comprobación añade un resultado: clave única, OK/FAIL, urgencia GLPI
# (1-5), título, detalle, acción sugerida y qué evidencias adjuntar.
R_KEY=(); R_STATUS=(); R_URG=(); R_TITLE=(); R_DETAIL=(); R_ACTION=(); R_EVID=()
add_result() {
  R_KEY+=("$1"); R_STATUS+=("$2"); R_URG+=("$3"); R_TITLE+=("$4")
  R_DETAIL+=("$5"); R_ACTION+=("$6"); R_EVID+=("$7")
}
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b>0) printf "%.1f", a*100/b; else print "0" }'; }
lt()  { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a<b) }'; }
human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

# 1) DISCO ---------------------------------------------------------------------
check_disk() {
  local excl=() t fstype size used avail mount free
  for t in $DISK_EXCLUDE_FSTYPES; do excl+=(-x "$t"); done
  while read -r fstype size used avail mount; do
    [ -n "$mount" ] && [ "$size" -gt 0 ] 2>/dev/null || continue
    free="$(pct "$avail" "$((used + avail))")"
    if lt "$free" "$DISK_FREE_PCT_MIN"; then
      local urg=4; lt "$free" "$DISK_FREE_PCT_CRITICAL" && urg=5
      add_result "disk:$mount" FAIL "$urg" \
        "Disco casi lleno en $mount ($free% libre)" \
        "Volumen $mount ($fstype): $free% libre — $(human $((avail*1024))) libres de $(human $((size*1024))). Umbral: $DISK_FREE_PCT_MIN% (crítico: $DISK_FREE_PCT_CRITICAL%)." \
        "Revisar en el adjunto las carpetas que más ocupan. Liberar logs rotados, cachés de paquetes (apt/dnf clean) y temporales, o ampliar el volumen." \
        "disk:$mount"
    else
      add_result "disk:$mount" OK 0 "" "Volumen $mount: $free% libre" "" ""
    fi
  done < <(df -l -k --output=fstype,size,used,avail,target "${excl[@]}" 2>/dev/null | tail -n +2)
}

# 2) SERVICIOS -----------------------------------------------------------------
check_services() {
  local svc st load
  [ -n "$SERVICES" ] || return 0
  if ! systemctl list-units --type=service --no-legend >/dev/null 2>&1; then
    log WARN "systemd no está disponible en este equipo: se omite la comprobación de servicios"
    return 0
  fi
  for svc in $SERVICES; do
    load="$(systemctl show -p LoadState --value "$svc" 2>/dev/null)"
    if [ "$load" = "not-found" ]; then
      add_result "service:$svc" FAIL 4 "Servicio crítico $svc no existe" \
        "El servicio $svc está configurado como crítico pero no existe en el equipo." \
        "Verificar si se ha desinstalado o renombrado el servicio, o corregir la configuración del monitor." \
        "service:$svc"
      continue
    fi
    st="$(systemctl is-active "$svc" 2>/dev/null)"
    if [ "$st" = "active" ]; then
      add_result "service:$svc" OK 0 "" "Servicio $svc activo" "" ""
      continue
    fi
    if [ "$AUTO_RESTART_SERVICES" = true ] && ! $DRY_RUN; then
      log INFO "Servicio $svc en estado '$st': intento de reinicio automático"
      systemctl restart "$svc" >/dev/null 2>&1; sleep 5
      if [ "$(systemctl is-active "$svc" 2>/dev/null)" = "active" ]; then
        add_result "service:$svc" FAIL 2 "Servicio $svc caído — reiniciado automáticamente" \
          "El servicio $svc estaba en estado '$st'. El monitor lo reinició y ahora está activo. Se abre ticket para analizar la causa raíz." \
          "Revisar en el adjunto el journal del servicio para averiguar por qué se detuvo. Si se repite, abrir un Problema." \
          "service:$svc"
        continue
      fi
    fi
    add_result "service:$svc" FAIL 4 "Servicio crítico $svc detenido ($st)" \
      "El servicio $svc está en estado '$st'$([ "$AUTO_RESTART_SERVICES" = true ] && echo ' y el reinicio automático ha fallado')." \
      "Revisar el journal del servicio en el adjunto (errores de configuración, dependencias, puertos, permisos) y arrancarlo: systemctl start $svc" \
      "service:$svc"
  done
}

# 3) REINICIO PENDIENTE --------------------------------------------------------
check_reboot() {
  local pending=false reason="" since now days uptime_days
  now="$(date +%s)"
  if [ -f /var/run/reboot-required ]; then
    pending=true; reason="/var/run/reboot-required presente"
    since="$(stat -c %Y /var/run/reboot-required)"   # fecha real en que se pidió
  elif command -v needs-restarting >/dev/null 2>&1; then
    needs-restarting -r >/dev/null 2>&1; [ $? -eq 1 ] && { pending=true; reason="needs-restarting -r indica reinicio"; }
  fi
  uptime_days="$(awk '{printf "%d", $1/86400}' /proc/uptime)"

  if $pending; then
    local stored; stored="$(meta_get reboot_pending_since)"
    [ -z "${since:-}" ] && since="${stored:-$now}"
    [ -n "$stored" ] && [ "$stored" -lt "$since" ] && since="$stored"
    meta_set reboot_pending_since "$since"
    days=$(( (now - since) / 86400 ))
    if [ "$days" -ge "$REBOOT_PENDING_MAX_DAYS" ]; then
      add_result "reboot" FAIL 3 "Reinicio pendiente desde hace $days días" \
        "El equipo necesita reiniciarse para aplicar actualizaciones ($reason) desde hace $days días (umbral: $REBOOT_PENDING_MAX_DAYS). Uptime: $uptime_days días." \
        "Planificar reinicio en ventana de mantenimiento: los parches de seguridad no están activos hasta reiniciar." \
        "reboot"
      return
    fi
  else
    meta_del reboot_pending_since
  fi
  if [ "$MAX_UPTIME_DAYS" -gt 0 ] && [ "$uptime_days" -ge "$MAX_UPTIME_DAYS" ]; then
    add_result "reboot" FAIL 3 "Equipo sin reiniciar desde hace $uptime_days días" \
      "Uptime de $uptime_days días (máximo configurado: $MAX_UPTIME_DAYS)." \
      "Planificar reinicio en ventana de mantenimiento." "reboot"
  else
    add_result "reboot" OK 0 "" "Sin reinicio pendiente fuera de plazo" "" ""
  fi
}

# 4) COPIAS DE SEGURIDAD -------------------------------------------------------
# BACKUP_CHECKS=( "Nombre|/ruta/patrón*.tar.gz|horas_máximas" )
check_backups() {
  local entry name glob maxh dir pat newest mtime size age_h key
  for entry in "${BACKUP_CHECKS[@]}"; do
    IFS='|' read -r name glob maxh <<<"$entry"
    dir="$(dirname "$glob")"; pat="$(basename "$glob")"
    key="backup:$name"
    newest="$(find "$dir" -maxdepth 1 -type f -name "$pat" -printf '%T@ %s %p\n' 2>/dev/null | sort -nr | head -1)"
    if [ -z "$newest" ]; then
      add_result "$key" FAIL 4 "Copia de seguridad '$name' no encontrada" \
        "No existe ningún fichero que cumpla $glob (o la ruta no es accesible)." \
        "Comprobar que el trabajo de copia se ejecuta y que el destino está montado." "backup:$name|$glob"
      continue
    fi
    read -r mtime size _ <<<"$newest"; mtime="${mtime%.*}"
    age_h=$(( ($(date +%s) - mtime) / 3600 ))
    if [ "$size" -eq 0 ]; then
      add_result "$key" FAIL 4 "Copia de seguridad '$name' vacía (0 bytes)" \
        "La última copia (${newest#* * }) tiene 0 bytes." \
        "Revisar el log del trabajo de copia: probablemente falló a mitad." "backup:$name|$glob"
    elif [ "$age_h" -gt "$maxh" ]; then
      add_result "$key" FAIL 4 "Copia de seguridad '$name' desactualizada ($age_h h)" \
        "La última copia tiene $age_h horas (máximo: $maxh h): ${newest#* * }" \
        "Comprobar el planificador del trabajo de copia y su último log de ejecución." "backup:$name|$glob"
    else
      add_result "$key" OK 0 "" "Copia '$name' de hace $age_h h" "" ""
    fi
  done
}

# Simulacro: fallos ficticios con claves 'sim:' (no tocan el estado real)
simulate() {
  local t
  for t in ${SIMULATE//,/ }; do
    case "$t" in
      all) SIMULATE="disk,service,reboot,backup"; simulate; return ;;
      disk)    add_result "sim:disk" FAIL 4 "[SIMULACRO] Disco casi lleno en / (4.2% libre)" \
                 "Fallo ficticio generado con --simulate para validar la integración con GLPI." \
                 "Ninguna: es un simulacro. Se cerrará solo en la próxima ejecución normal." "disk:/" ;;
      service) add_result "sim:service" FAIL 4 "[SIMULACRO] Servicio crítico detenido" \
                 "Fallo ficticio generado con --simulate." "Ninguna: es un simulacro." "summary" ;;
      reboot)  add_result "sim:reboot" FAIL 3 "[SIMULACRO] Reinicio pendiente desde hace 21 días" \
                 "Fallo ficticio generado con --simulate." "Ninguna: es un simulacro." "reboot" ;;
      backup)  add_result "sim:backup" FAIL 4 "[SIMULACRO] Copia de seguridad desactualizada (49 h)" \
                 "Fallo ficticio generado con --simulate." "Ninguna: es un simulacro." "summary" ;;
      *) die "Tipo de simulacro desconocido: $t" ;;
    esac
  done
}

# --------------------------------------------------------------- evidencias --
section() { printf '\n===== %s =====\n' "$1"; }
collect_evidence() {  # collect_evidence <spec> <fichero>
  local spec="$1" out="$2"
  {
    echo "Diagnóstico generado por glpi-monitor $VERSION"
    echo "Equipo:   $COMPUTER_NAME ($(hostname -f 2>/dev/null))"
    echo "Fecha:    $(date '+%F %T %Z')"
    echo "IPs:      $(hostname -I 2>/dev/null)"
    echo "SO:       $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-desconocido}") · kernel $(uname -r)"
    echo "Uptime:   $(uptime -p 2>/dev/null)  (arrancado: $(uptime -s 2>/dev/null))"
    case "$spec" in
      disk:*)
        local m="${spec#disk:}"
        section "Espacio en disco"; df -h -x tmpfs -x devtmpfs -x squashfs 2>/dev/null
        section "Inodos";           df -i "$m" 2>/dev/null
        section "Carpetas que más ocupan en $m (máx. 60 s)"
        timeout 60 du -xh --max-depth=2 "$m" 2>/dev/null | sort -rh | head -25
        section "Ficheros abiertos pero borrados (siguen ocupando espacio)"
        if command -v lsof >/dev/null; then timeout 30 lsof -nP +L1 2>/dev/null | head -20; else echo "(lsof no instalado)"; fi
        ;;
      service:*)
        local s="${spec#service:}"
        section "systemctl status $s"; systemctl status "$s" --no-pager -l -n 30 2>&1
        section "Journal de $s (últimas 150 líneas)"; journalctl -u "$s" -n 150 --no-pager 2>&1
        ;;
      reboot)
        section "Motivo del reinicio pendiente"
        [ -f /var/run/reboot-required ] && ls -l /var/run/reboot-required
        [ -f /var/run/reboot-required.pkgs ] && { echo "Paquetes:"; cat /var/run/reboot-required.pkgs; }
        command -v needs-restarting >/dev/null && needs-restarting -r 2>&1
        section "Últimos reinicios"; last -x reboot 2>/dev/null | head -10
        ;;
      backup:*)
        local g="${spec#*|}"
        section "Contenido del destino de copia ($(dirname "$g"))"
        ls -lt --time-style=long-iso "$(dirname "$g")" 2>&1 | head -25
        section "Montajes";  findmnt -D 2>/dev/null | head -30
        ;;
    esac
    section "Servicios en estado failed"; systemctl --failed --no-pager 2>&1
    section "Errores del sistema (últimas 24 h)"
    journalctl -p err -S -24h -n 60 --no-pager 2>&1
  } > "$out" 2>&1
}

# ---------------------------------------------------------------- API GLPI --
SESSION=""
API_CODE=""; API_BODY=""
CURL_BASE=(-sS --max-time 30 --proto "=https,http")
[ -n "$GLPI_CA_BUNDLE" ] && CURL_BASE+=(--cacert "$GLPI_CA_BUNDLE")
HDR_FILE="$WORK_DIR/session.hdr"

# Los tokens se pasan a curl desde un fichero (-H @fichero) y no en la línea
# de comandos, para que no aparezcan en 'ps' a otros usuarios del equipo.
api() {  # api METODO ruta [args curl...]  -> API_CODE / API_BODY
  local method="$1" path="$2"; shift 2
  local retry=(); [ "$method" = GET ] && retry=(--retry 2 --retry-delay 3)
  local resp
  resp="$(curl "${CURL_BASE[@]}" "${retry[@]}" -H @"$HDR_FILE" -X "$method" \
          -w $'\n%{http_code}' "$GLPI_URL/$path" "$@" 2>&1)"
  API_CODE="${resp##*$'\n'}"; API_BODY="${resp%$'\n'*}"
  [[ "$API_CODE" =~ ^2 ]]
}

glpi_login() {
  [ -n "$SESSION" ] && return 0
  local auth="$WORK_DIR/auth.hdr" resp code body
  printf 'App-Token: %s\nAuthorization: user_token %s\n' "$GLPI_APP_TOKEN" "$GLPI_USER_TOKEN" > "$auth"
  resp="$(curl "${CURL_BASE[@]}" --retry 2 --retry-delay 3 -H @"$auth" -w $'\n%{http_code}' "$GLPI_URL/initSession" 2>&1)"
  rm -f "$auth"
  code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
  SESSION="$(jq -r '.session_token // empty' <<<"$body" 2>/dev/null)"
  if [ -z "$SESSION" ]; then
    log ERROR "No se pudo iniciar sesión en GLPI (HTTP $code): $(head -c 300 <<<"$body")"
    return 1
  fi
  printf 'App-Token: %s\nSession-Token: %s\n' "$GLPI_APP_TOKEN" "$SESSION" > "$HDR_FILE"
}
glpi_logout() { [ -n "$SESSION" ] && api GET killSession >/dev/null; SESSION=""; rm -f "$HDR_FILE"; }

COMPUTER_ID=""
find_computer() {
  [ -n "$COMPUTER_ID" ] && return 0
  api GET Computer -G --data-urlencode "searchText[name]=$COMPUTER_NAME" --data-urlencode "range=0-49" || true
  COMPUTER_ID="$(jq -r --arg n "$COMPUTER_NAME" \
    'if type=="array" then (map(select((.name|ascii_downcase)==($n|ascii_downcase)))[0].id // empty) else empty end' \
    <<<"$API_BODY" 2>/dev/null)"
  [ -n "$COMPUTER_ID" ] || log WARN "Equipo '$COMPUTER_NAME' no encontrado en el inventario de GLPI: el ticket no irá vinculado"
}

ticket_status() {  # imprime el estado (1-6), 'gone' si no existe o vacío si no se pudo consultar
  if api GET "Ticket/$1"; then jq -r '.status // empty' <<<"$API_BODY"
  elif [ "$API_CODE" = 404 ] || [ "$API_CODE" = 400 ]; then echo gone
  fi
}

upload_document() {  # upload_document <ticket_id> <fichero> <nombre visible>
  local tid="$1" file="$2" title="$3" fname manifest
  fname="$(basename "$file")"; manifest="$WORK_DIR/manifest.json"
  jq -n --arg name "$title" --arg f "$fname" --argjson tid "$tid" \
    '{input:{name:$name, _filename:[$f], itemtype:"Ticket", items_id:$tid}}' > "$manifest"
  if api POST Document -F "uploadManifest=<$manifest;type=application/json" \
                       -F "filename[0]=@$file;filename=$fname;type=text/plain"; then
    log INFO "Diagnóstico adjuntado al ticket #$tid (documento #$(jq -r .id <<<"$API_BODY"))"
  else
    log WARN "No se pudo adjuntar el diagnóstico al ticket #$tid (HTTP $API_CODE): $(head -c 200 <<<"$API_BODY")"
  fi
}

add_followup() {  # add_followup <ticket_id> <html>
  local body; body="$(jq -n --argjson t "$1" --arg c "$2" '{input:{itemtype:"Ticket", items_id:$t, content:$c}}')"
  api POST ITILFollowup -H 'Content-Type: application/json' --data-binary "$body" \
    || log WARN "No se pudo añadir seguimiento al ticket #$1 (HTTP $API_CODE)"
}

ticket_html() {  # ticket_html <idx>
  local i="$1"
  jq -rn --arg host "$COMPUTER_NAME" --arg ip "$(hostname -I 2>/dev/null | awk '{print $1}')" \
     --arg os "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")" \
     --arg check "${R_KEY[$i]}" --arg detail "${R_DETAIL[$i]}" --arg action "${R_ACTION[$i]}" \
     --arg when "$(date '+%d/%m/%Y %H:%M')" --arg ver "$VERSION" '
    "<p><strong>Alerta proactiva</strong> detectada automáticamente por <em>glpi-monitor</em>, antes de que el usuario lo notifique.</p>" +
    "<table border=\"1\" cellpadding=\"4\" cellspacing=\"0\">" +
    "<tr><td style=\"white-space:nowrap\"><strong>Equipo</strong></td><td>\($host|@html) (\($ip|@html))</td></tr>" +
    "<tr><td style=\"white-space:nowrap\"><strong>Sistema</strong></td><td>\($os|@html)</td></tr>" +
    "<tr><td style=\"white-space:nowrap\"><strong>Comprobación</strong></td><td>\($check|@html)</td></tr>" +
    "<tr><td style=\"white-space:nowrap\"><strong>Detalle</strong></td><td>\($detail|@html)</td></tr>" +
    "<tr><td style=\"white-space:nowrap\"><strong>Detectado</strong></td><td>\($when)</td></tr></table>" +
    "<p><strong>Acción sugerida:</strong> \($action|@html)</p>" +
    "<p>Se adjunta el diagnóstico completo del equipo. <small>glpi-monitor \($ver) (Linux)</small></p>"'
}

evidence_file() {  # evidence_file <idx> -> ruta
  local i="$1" safe f
  safe="$(tr -c 'A-Za-z0-9_-' '_' <<<"${R_KEY[$i]}" | sed 's/_*$//')"
  f="$WORK_DIR/diag_${COMPUTER_NAME}_${safe}_$(date +%Y%m%d-%H%M).txt"
  collect_evidence "${R_EVID[$i]:-summary}" "$f"
  echo "$f"
}

create_ticket() {  # create_ticket <idx>
  local i="$1" body tid
  glpi_login || return 1
  find_computer
  body="$(jq -n --arg name "[Monitor] $COMPUTER_NAME · ${R_TITLE[$i]}" --arg content "$(ticket_html "$i")" \
      --argjson urg "${R_URG[$i]}" --arg comp "$COMPUTER_ID" --arg ent "$ENTITIES_ID" \
      --arg cat "$ITILCATEGORIES_ID" --arg rt "$REQUESTTYPES_ID" --arg grp "$GROUPS_ID_ASSIGN" '
      {input: ({name:$name, content:$content, type:1, urgency:$urg}
        + (if $comp != "" then {items_id:{Computer:[($comp|tonumber)]}} else {} end)
        + (if $ent  != "" then {entities_id:($ent|tonumber)} else {} end)
        + (if $cat  != "" then {itilcategories_id:($cat|tonumber)} else {} end)
        + (if $rt   != "" then {requesttypes_id:($rt|tonumber)} else {} end)
        + (if $grp  != "" then {_groups_id_assign:($grp|tonumber)} else {} end))}')"
  if ! api POST Ticket -H 'Content-Type: application/json' --data-binary "$body"; then
    log ERROR "No se pudo crear el ticket para ${R_KEY[$i]} (HTTP $API_CODE): $(head -c 300 <<<"$API_BODY")"
    return 1
  fi
  tid="$(jq -r '.id' <<<"$API_BODY")"
  log INFO "Ticket #$tid creado: ${R_TITLE[$i]}"
  upload_document "$tid" "$(evidence_file "$i")" "Diagnóstico $COMPUTER_NAME · ${R_KEY[$i]}"
  state_update '.checks[$k] = {ticket_id:($t|tonumber), opened:$now, last_followup:$now, title:$title}' \
    --arg k "${R_KEY[$i]}" --arg t "$tid" --arg now "$(date +%s)" --arg title "${R_TITLE[$i]}"
}

# ------------------------------------------------------------ orquestación --
handle_fail() {  # handle_fail <idx>
  local i="$1"; local key="${R_KEY[$i]}" tid st last now
  tid="$(state_get "$key" ticket_id)"
  if $DRY_RUN; then
    if [ -n "$tid" ]; then echo "  [dry-run] Ya existe ticket #$tid para $key → se comprobaría su estado / seguimiento"
    else
      echo "  [dry-run] Se crearía ticket: [Monitor] $COMPUTER_NAME · ${R_TITLE[$i]} (urgencia ${R_URG[$i]})"
      echo "            Detalle: ${R_DETAIL[$i]}"
      echo "            Acción:  ${R_ACTION[$i]}"
    fi
    return
  fi
  if [ -n "$tid" ]; then
    glpi_login || return 1
    st="$(ticket_status "$tid")"
    if [ -z "$st" ]; then
      log WARN "No se pudo consultar el ticket #$tid (HTTP $API_CODE); no se crea otro para evitar duplicados"
      return
    elif [ "$st" != gone ] && [ "$st" -lt 5 ]; then
      now="$(date +%s)"; last="$(state_get "$key" last_followup)"
      if [ $(( now - ${last:-0} )) -ge $(( FOLLOWUP_EVERY_HOURS * 3600 )) ]; then
        add_followup "$tid" "<p><strong>El problema continúa.</strong> $(jq -rn --arg d "${R_DETAIL[$i]}" '$d|@html')</p><p>Se adjunta diagnóstico actualizado.</p>"
        upload_document "$tid" "$(evidence_file "$i")" "Diagnóstico actualizado $COMPUTER_NAME · $key"
        state_update '.checks[$k].last_followup = $now' --arg k "$key" --arg now "$now"
        log INFO "Ticket #$tid sigue abierto: seguimiento añadido"
      else
        log INFO "Ticket #$tid sigue abierto para $key: sin acción (próximo seguimiento en < ${FOLLOWUP_EVERY_HOURS} h)"
      fi
      return
    fi
    log INFO "El ticket #$tid de $key está resuelto/cerrado pero el problema ha vuelto: se abre uno nuevo"
    state_del "$key"
  fi
  if [ "$TICKETS_CREATED" -ge "$MAX_TICKETS_PER_RUN" ]; then
    log WARN "Límite de $MAX_TICKETS_PER_RUN tickets por ejecución alcanzado; $key queda para la siguiente"
    return
  fi
  create_ticket "$i" && TICKETS_CREATED=$((TICKETS_CREATED + 1))
}

handle_recovery() {  # handle_recovery <idx>
  local i="$1"; local key="${R_KEY[$i]}" tid st
  tid="$(state_get "$key" ticket_id)"; [ -n "$tid" ] || return
  if $DRY_RUN; then echo "  [dry-run] $key recuperado → se añadiría seguimiento al ticket #$tid"; return; fi
  if [ "$NOTIFY_RECOVERY" = true ]; then
    glpi_login || return 1
    st="$(ticket_status "$tid")"
    if [ -n "$st" ] && [ "$st" != gone ] && [ "$st" -lt 5 ]; then
      add_followup "$tid" "<p><strong>✔ Recuperado automáticamente.</strong> $(jq -rn --arg d "${R_DETAIL[$i]}" '$d|@html') ($(date '+%d/%m/%Y %H:%M')).</p><p>El técnico puede verificar y resolver el ticket.</p>"
      log INFO "$key recuperado: seguimiento añadido al ticket #$tid"
    fi
  fi
  state_del "$key"
}

main() {
  state_init
  if $TEST_ONLY; then
    echo "Probando conexión con $GLPI_URL ..."
    glpi_login || exit 2
    echo "  ✔ Sesión iniciada (App-Token y User-Token válidos)"
    find_computer
    [ -n "$COMPUTER_ID" ] && echo "  ✔ Equipo '$COMPUTER_NAME' encontrado en el inventario (Computer #$COMPUTER_ID)" \
                          || echo "  ⚠ Equipo '$COMPUTER_NAME' no encontrado: los tickets se crearán sin vincular"
    glpi_logout; echo "  ✔ Sesión cerrada"; exit 0
  fi

  if [ -n "$SIMULATE" ]; then
    simulate
  else
    check_disk; check_services; check_reboot; check_backups
    # Los simulacros anteriores se dan por recuperados en una ejecución normal
    local k; while read -r k; do
      [[ "$k" == sim:* ]] && add_result "$k" OK 0 "" "Simulacro finalizado" "" ""
    done < <(state_keys)
  fi

  TICKETS_CREATED=0
  local i fails=0
  for i in "${!R_KEY[@]}"; do
    if [ "${R_STATUS[$i]}" = FAIL ]; then
      fails=$((fails + 1)); log WARN "FALLO ${R_KEY[$i]}: ${R_TITLE[$i]}"
      handle_fail "$i"
    else
      $DRY_RUN && echo "  OK   ${R_DETAIL[$i]}"
      handle_recovery "$i"
    fi
  done
  glpi_logout
  log INFO "Ejecución terminada: ${#R_KEY[@]} comprobaciones, $fails fallos, $TICKETS_CREATED tickets nuevos"
  [ "$fails" -eq 0 ]
}

main && exit 0 || exit 1
