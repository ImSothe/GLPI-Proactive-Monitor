#!/usr/bin/env bash
# =============================================================================
#  glpi-backup.sh — Copia de seguridad diaria de GLPI
#
#  Genera dos ficheros por ejecución en BACKUP_DIR:
#    glpi-db_AAAAMMDD-HHMM.sql.gz     volcado completo de la base de datos
#    glpi-files_AAAAMMDD-HHMM.tar.gz  config/ (incluye glpicrypt.key), files/
#                                     (adjuntos), marketplace/ y plugins/
#
#  - Escribe primero en *.partial y solo renombra si todo ha ido bien, así
#    una copia a medias nunca parece válida (ni al monitor ni a ti).
#  - Verifica el gzip y que el volcado termina con "Dump completed".
#  - Borra copias de más de KEEP_DAYS días.
#  - Opcional: copia el resultado a OFFSITE_DIR (NAS montado, etc.).
#
#  Sin glpicrypt.key una copia NO se puede restaurar del todo: GLPI no podría
#  descifrar tokens ni contraseñas guardadas. Por eso va siempre incluida y los
#  ficheros se crean con permisos 600.
#
#  Uso: glpi-backup.sh [-c /etc/glpi-backup.conf]
# =============================================================================
set -uo pipefail
umask 077

CONFIG_FILE="/etc/glpi-backup.conf"
[ "${1:-}" = "-c" ] && CONFIG_FILE="${2:?Falta el fichero}"

# ----------------------------------------------------------------- defaults --
DB_NAME="glpi"
MYSQL_DEFAULTS_FILE=""          # vacío = root por socket (lo normal en Ubuntu/MariaDB)
GLPI_PATHS="/var/www/glpi/config /var/www/glpi/files /var/www/glpi/marketplace /var/www/glpi/plugins"
BACKUP_DIR="/var/backups/glpi"
KEEP_DAYS=14
OFFSITE_DIR=""                  # p. ej. /mnt/nas/glpi (debe estar montado)

if [ -r "$CONFIG_FILE" ]; then
  mode="$(stat -c '%a' "$CONFIG_FILE")"
  (( 8#$mode & 8#022 )) && { echo "ERROR: $CONFIG_FILE es modificable por otros (chmod 600)" >&2; exit 2; }
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi

log() { echo "$(date '+%F %T') [$1] $2"; }
fail() { log ERROR "$1"; rm -f "$BACKUP_DIR"/*.partial; exit 1; }

DUMP_BIN="$(command -v mariadb-dump || command -v mysqldump)" || fail "No se encuentra mariadb-dump ni mysqldump"
MYSQL_OPTS=()
[ -n "$MYSQL_DEFAULTS_FILE" ] && MYSQL_OPTS+=(--defaults-extra-file="$MYSQL_DEFAULTS_FILE")

mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || fail "No se puede crear $BACKUP_DIR"
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { log WARN "Ya hay una copia en curso; salgo"; exit 0; }

STAMP="$(date +%Y%m%d-%H%M)"
DB_FILE="$BACKUP_DIR/glpi-db_$STAMP.sql.gz"
FILES_FILE="$BACKUP_DIR/glpi-files_$STAMP.tar.gz"

# 1) Base de datos ------------------------------------------------------------
# --single-transaction: copia consistente sin bloquear GLPI (tablas InnoDB)
log INFO "Volcando la base de datos '$DB_NAME'..."
"$DUMP_BIN" "${MYSQL_OPTS[@]}" --single-transaction --quick --routines --triggers \
  --default-character-set=utf8mb4 "$DB_NAME" | gzip -6 > "$DB_FILE.partial"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "El volcado de la base de datos ha fallado"
gzip -t "$DB_FILE.partial" || fail "El fichero del volcado está corrupto"
zcat "$DB_FILE.partial" | tail -n 1 | grep -q "Dump completed" || fail "El volcado está incompleto (falta 'Dump completed')"
mv "$DB_FILE.partial" "$DB_FILE"
log INFO "Base de datos OK: $DB_FILE ($(du -h "$DB_FILE" | cut -f1))"

# 2) Ficheros -----------------------------------------------------------------
paths=()
for p in $GLPI_PATHS; do
  if [ -d "$p" ]; then paths+=("$p"); else log WARN "No existe $p: se omite"; fi
done
[ ${#paths[@]} -gt 0 ] || fail "Ninguna de las rutas de GLPI_PATHS existe"
found_key=false
for p in "${paths[@]}"; do [ -f "$p/glpicrypt.key" ] && found_key=true; done
$found_key || log WARN "No se ha encontrado glpicrypt.key en las rutas copiadas: la restauración no podrá descifrar tokens/contraseñas"

log INFO "Copiando ficheros: ${paths[*]}"
# Rutas absolutas guardadas sin la / inicial: se restauran con 'tar -xzf ... -C /'
# Se excluyen caché, sesiones y temporales: se regeneran solos, y las sesiones
# activas de los usuarios son un dato sensible que no debe acabar en una copia.
tar --create --gzip --file "$FILES_FILE.partial" --absolute-names --transform 's,^/,,' \
    --warning=no-file-changed \
    --exclude='*/files/_cache' --exclude='*/files/_sessions' --exclude='*/files/_tmp' \
    --exclude='*/files/_locks' --exclude='*/files/_graphs' --exclude='*/files/_rss' \
    "${paths[@]}"
rc=$?
[ $rc -le 1 ] || fail "tar ha fallado (código $rc)"     # 1 = algún fichero cambió durante la copia
gzip -t "$FILES_FILE.partial" || fail "El fichero de adjuntos está corrupto"
mv "$FILES_FILE.partial" "$FILES_FILE"
log INFO "Ficheros OK: $FILES_FILE ($(du -h "$FILES_FILE" | cut -f1))"

# 3) Copia fuera del servidor (opcional) --------------------------------------
if [ -n "$OFFSITE_DIR" ]; then
  if mountpoint -q "$OFFSITE_DIR" 2>/dev/null || [ -d "$OFFSITE_DIR" ]; then
    cp -p "$DB_FILE" "$FILES_FILE" "$OFFSITE_DIR"/ \
      && log INFO "Copiado también a $OFFSITE_DIR" \
      || fail "No se pudo copiar a $OFFSITE_DIR"
    find "$OFFSITE_DIR" -maxdepth 1 -name 'glpi-*_*.gz' -mtime +"$KEEP_DAYS" -delete
  else
    fail "OFFSITE_DIR=$OFFSITE_DIR no está disponible (¿NAS sin montar?)"
  fi
fi

# 4) Rotación ------------------------------------------------------------------
deleted="$(find "$BACKUP_DIR" -maxdepth 1 -name 'glpi-*_*.gz' -mtime +"$KEEP_DAYS" -print -delete | wc -l)"
log INFO "Rotación: $deleted copias de más de $KEEP_DAYS días eliminadas. Copias guardadas: $(find "$BACKUP_DIR" -maxdepth 1 -name 'glpi-db_*.sql.gz' | wc -l)"
log INFO "Copia terminada correctamente"
