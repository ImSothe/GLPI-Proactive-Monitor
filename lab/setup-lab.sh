#!/usr/bin/env bash
# =============================================================================
#  setup-lab.sh — Levanta un GLPI 11 de laboratorio y lo deja listo para el
#  monitor: API REST activada, App-Token, usuario técnico con perfil de
#  MÍNIMO PRIVILEGIO y un equipo de prueba en el inventario.
#
#  SOLO PARA LABORATORIO: los tokens se imprimen por pantalla.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

LAB_HOST="${LAB_HOST:-$(hostname)}"   # equipo que se dará de alta en el inventario
GLPI_URL="http://localhost:8080"

sql()  { docker exec -i glpi-db mariadb -uglpi -pglpipw glpi -N -e "$1"; }
encrypt() {  # Cifra con la clave de GLPI (los tokens se guardan cifrados en BD)
  docker exec glpi php -r 'require "/var/www/glpi/vendor/autoload.php";
    echo (new GLPIKey("/var/glpi/config"))->encrypt($argv[1]);' "$1"
}

echo "[1/6] Levantando contenedores..."
docker compose up -d

echo "[2/6] Esperando a que GLPI termine la autoinstalación..."
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null "$GLPI_URL/" 2>/dev/null \
     && [ "$(sql "select count(*) from glpi_configs where name='enable_api'" 2>/dev/null)" = "1" ]; then
    break
  fi
  sleep 3
done

echo "[3/6] Activando la API REST (legacy, apirest.php)..."
sql "update glpi_configs set value='1' where name='enable_api';
     update glpi_configs set value='0' where name='enable_api_login_credentials';
     update glpi_configs set value='1' where name='enable_api_login_external_token';"

echo "[4/6] Creando cliente API con App-Token..."
APP_TOKEN="$(openssl rand -hex 20)"
# Laboratorio: sin restricción de IP. En producción, limita al rango de tu red.
sql "update glpi_apiclients
       set name='Monitor proactivo (lab)', is_active=1,
           ipv4_range_start=NULL, ipv4_range_end=NULL, ipv6=NULL,
           app_token='$(encrypt "$APP_TOKEN")', app_token_date=NOW()
     where id=1;"

echo "[5/6] Creando perfil 'API Monitor' (mínimo privilegio) y usuario svc-glpi-monitor..."
PROFILE_ID="$(sql "select id from glpi_profiles where name='API Monitor'")"
if [ -z "$PROFILE_ID" ]; then
  sql "insert into glpi_profiles (name, interface, is_default, helpdesk_hardware, use_mentions,
         create_ticket_on_login, date_creation, comment)
       values ('API Monitor', 'central', 0, 0, 0, 0, NOW(),
               'Perfil técnico para el monitor proactivo. Solo crear/leer sus tickets, adjuntar documentos y leer equipos.');"
  PROFILE_ID="$(sql "select id from glpi_profiles where name='API Monitor'")"
fi
# Derechos (bitmask GLPI): READ=1 CREATE=4 · ticket READMY=1 · followup SEEPUBLIC=1 ADDMY=4
sql "delete from glpi_profilerights where profiles_id=$PROFILE_ID;
     insert into glpi_profilerights (profiles_id, name, rights) values
       ($PROFILE_ID, 'ticket',   5),
       ($PROFILE_ID, 'followup', 5),
       ($PROFILE_ID, 'document', 5),
       ($PROFILE_ID, 'computer', 1);"

docker exec glpi php /var/www/glpi/bin/console user:create svc-glpi-monitor \
  --password="$(openssl rand -base64 24)" -n >/dev/null 2>&1 || true
USER_ID="$(sql "select id from glpi_users where name='svc-glpi-monitor'")"
sql "delete from glpi_profiles_users where users_id=$USER_ID;
     insert into glpi_profiles_users (users_id, profiles_id, entities_id, is_recursive, is_dynamic, is_default_profile)
       values ($USER_ID, $PROFILE_ID, 0, 1, 0, 1);
     update glpi_users set profiles_id=$PROFILE_ID, entities_id=0 where id=$USER_ID;"
USER_TOKEN="$(openssl rand -hex 20)"
sql "update glpi_users set api_token='$(encrypt "$USER_TOKEN")', api_token_date=NOW() where id=$USER_ID;"

echo "[6/6] Dando de alta el equipo '$LAB_HOST' en el inventario..."
if [ -z "$(sql "select id from glpi_computers where name='$LAB_HOST'")" ]; then
  sql "insert into glpi_computers (entities_id, name, is_deleted, is_template, date_creation, date_mod)
       values (0, '$LAB_HOST', 0, 0, NOW(), NOW());"
fi

echo "      ...y el grupo técnico 'Sistemas N2' para la asignación automática"
if [ -z "$(sql "select id from glpi_groups where name='Sistemas N2'")" ]; then
  sql "insert into glpi_groups (entities_id, is_recursive, name, completename, level, is_assign,
         is_requester, is_watcher, is_notify, is_itemgroup, is_usergroup, is_manager, date_creation)
       values (0, 1, 'Sistemas N2', 'Sistemas N2', 1, 1, 1, 1, 1, 1, 1, 1, NOW());"
fi
GROUP_ID="$(sql "select id from glpi_groups where name='Sistemas N2'")"

cat <<EOF

=====================================================================
 GLPI de laboratorio listo:  $GLPI_URL   (usuario web: glpi / glpi)

   GLPI_URL=$GLPI_URL/apirest.php
   APP_TOKEN=$APP_TOKEN
   USER_TOKEN=$USER_TOKEN
   GROUPS_ID_ASSIGN=$GROUP_ID   (grupo "Sistemas N2")
=====================================================================
EOF
