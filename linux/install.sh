#!/usr/bin/env bash
# Instala glpi-monitor en Linux con un timer de systemd (cada hora, con retardo aleatorio).
# Uso: sudo ./install.sh            -> instala
#      sudo ./install.sh --uninstall
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta como root (sudo)"; exit 1; }
cd "$(dirname "$0")"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl disable --now glpi-monitor.timer 2>/dev/null || true
  rm -f /etc/systemd/system/glpi-monitor.{service,timer} /usr/local/sbin/glpi-monitor
  systemctl daemon-reload
  echo "Desinstalado (se conservan /etc/glpi-monitor y /var/lib/glpi-monitor)"; exit 0
fi

for bin in curl jq; do command -v $bin >/dev/null || { echo "Instala '$bin' primero (apt/dnf install $bin)"; exit 1; }; done

install -m 755 glpi-monitor.sh /usr/local/sbin/glpi-monitor
install -d -m 700 /etc/glpi-monitor /var/lib/glpi-monitor
if [ ! -f /etc/glpi-monitor/glpi-monitor.conf ]; then
  install -m 600 glpi-monitor.conf.example /etc/glpi-monitor/glpi-monitor.conf
  echo ">> Edita /etc/glpi-monitor/glpi-monitor.conf con la URL y los tokens de GLPI"
fi

cat > /etc/systemd/system/glpi-monitor.service <<'EOF'
[Unit]
Description=Monitor proactivo de salud con tickets en GLPI
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/glpi-monitor
# Códigos 0 (OK) y 1 (fallos detectados y gestionados) son ejecuciones correctas
SuccessExitStatus=1
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=10min
EOF

cat > /etc/systemd/system/glpi-monitor.timer <<'EOF'
[Unit]
Description=Ejecuta glpi-monitor cada hora

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
# Reparte la carga: no todos los equipos llaman a GLPI en el mismo minuto
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now glpi-monitor.timer
echo "Instalado. Prueba la conexión con:  sudo glpi-monitor --test"
echo "Valida la integración con:          sudo glpi-monitor --simulate all"
