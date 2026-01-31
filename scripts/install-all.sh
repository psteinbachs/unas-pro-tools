#!/bin/bash
# UNAS Pro Tools - Full Installation
# Installs monitoring stack + RustFS
set -e

SCRIPT_URL="https://raw.githubusercontent.com/psteinbachs/unas-pro-tools/main/scripts"

echo "=== UNAS Pro Tools - Full Installation ==="
echo ""

# Install monitoring first
curl -sL "$SCRIPT_URL/install-monitoring.sh" | bash

echo ""

# Install RustFS
curl -sL "$SCRIPT_URL/install-rustfs.sh" | bash

# Update restore script to include everything
cat > /persistent/system/restore.sh << 'RESTORE'
#!/bin/bash
cp /persistent/system/node_exporter.service /etc/systemd/system/
cp /persistent/system/smartctl_exporter.service /etc/systemd/system/
cp /persistent/system/otel-collector.service /etc/systemd/system/
cp /persistent/system/rustfs.service /etc/systemd/system/
echo "* * * * * root /persistent/bin/dmcache-metrics.sh" > /etc/cron.d/dmcache-metrics
systemctl daemon-reload
systemctl enable --now node_exporter smartctl_exporter otel-collector rustfs
echo "All services restored"
RESTORE
chmod +x /persistent/system/restore.sh

echo ""
echo "=== Full Installation Complete ==="
echo "After firmware upgrades, run: /persistent/system/restore.sh"
