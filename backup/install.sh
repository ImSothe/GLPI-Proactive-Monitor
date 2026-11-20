#!/usr/bin/env bash
# Instala glpi-backup con un timer de systemd (cada noche a las 02:30).
# Uso: sudo ./install.sh            -> instala
#      sudo ./install.sh --uninstall
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)"; exit 1; }
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now glpi-backup.timer 2>/dev/null || true
  rm -f /etc/systemd/system/glpi-backup.{service,timer} /usr/local/sbin/glpi-backup
  systemctl daemon-reload
  echo "Desinstalado (se conservan /etc/glpi-backup.conf y las copias de /var/backups/glpi)"; exit 0
fi

install -m 755 glpi-backup.sh /usr/local/sbin/glpi-backup
[ -f /etc/glpi-backup.conf ] || install -m 600 glpi-backup.conf.example /etc/glpi-backup.conf

cat > /etc/systemd/system/glpi-backup.service <<'EOF'
[Unit]
Description=Copia de seguridad de GLPI (base de datos y ficheros)
After=mariadb.service mysql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/glpi-backup
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=2h
EOF

cat > /etc/systemd/system/glpi-backup.timer <<'EOF'
[Unit]
Description=Copia de seguridad diaria de GLPI

[Timer]
OnCalendar=*-*-* 02:30
RandomizedDelaySec=15min
# Si el servidor estaba apagado a esa hora, la hace al arrancar
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now glpi-backup.timer
echo "Instalado. Primera copia manual:   sudo systemctl start glpi-backup && journalctl -u glpi-backup -n 20"
echo "Próxima copia automática:          systemctl list-timers glpi-backup.timer"
