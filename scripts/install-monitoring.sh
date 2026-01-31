#!/bin/bash
# UNAS Pro Tools - Monitoring Stack Installer
# Installs node_exporter, smartctl_exporter, and dm-cache metrics
set -e

PERSISTENT_BIN="/persistent/bin"
PERSISTENT_SYSTEM="/persistent/system"
TEXTFILE_DIR="/persistent/textfile_collector"

NODE_EXPORTER_VERSION="1.7.0"
SMARTCTL_EXPORTER_VERSION="0.12.0"

echo "=== UNAS Pro Tools - Monitoring Installer ==="
echo ""

if [ ! -d "/persistent" ]; then
    echo "ERROR: /persistent directory not found. Are you running on UNAS Pro?"
    exit 1
fi

mkdir -p "$PERSISTENT_BIN" "$PERSISTENT_SYSTEM" "$TEXTFILE_DIR"

ARCH=$(uname -m)
case $ARCH in
    aarch64) ARCH_SUFFIX="arm64" ;;
    x86_64)  ARCH_SUFFIX="amd64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

echo "Detected architecture: $ARCH_SUFFIX"

echo "Installing node_exporter v${NODE_EXPORTER_VERSION}..."
cd /tmp
curl -sLO "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}.tar.gz"
tar xzf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}.tar.gz"
mv "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}/node_exporter" "$PERSISTENT_BIN/"
rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}"*

echo "Installing smartctl_exporter v${SMARTCTL_EXPORTER_VERSION}..."
curl -sLO "https://github.com/prometheus-community/smartctl_exporter/releases/download/v${SMARTCTL_EXPORTER_VERSION}/smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}.tar.gz"
tar xzf "smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}.tar.gz"
mv "smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}/smartctl_exporter" "$PERSISTENT_BIN/"
rm -rf "smartctl_exporter-${SMARTCTL_EXPORTER_VERSION}.linux-${ARCH_SUFFIX}"*

echo "Creating dm-cache metrics collector..."
cat > "$PERSISTENT_BIN/dmcache-metrics.sh" << 'SCRIPT'
#!/bin/bash
OUTPUT_FILE="/persistent/textfile_collector/dmcache.prom"
dmsetup status 2>/dev/null | while read line; do
    if echo "$line" | grep -q " cache "; then
        dev=$(echo "$line" | cut -d: -f1)
        stats=$(echo "$line" | grep -oP "cache \K[0-9]+ [0-9]+/[0-9]+ [0-9]+ [0-9]+/[0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+")
        if [ -n "$stats" ]; then
            meta_used=$(echo "$stats" | awk '{split($2,a,"/"); print a[1]}')
            meta_total=$(echo "$stats" | awk '{split($2,a,"/"); print a[2]}')
            cache_used=$(echo "$stats" | awk '{split($4,a,"/"); print a[1]}')
            cache_total=$(echo "$stats" | awk '{split($4,a,"/"); print a[2]}')
            dirty=$(echo "$stats" | awk '{print $6}')
            read_hits=$(echo "$stats" | awk '{print $7}')
            read_misses=$(echo "$stats" | awk '{print $8}')
            write_hits=$(echo "$stats" | awk '{print $9}')
            write_misses=$(echo "$stats" | awk '{print $10}')
            cat << METRICS
# HELP dmcache_metadata_used_blocks Metadata blocks used
# TYPE dmcache_metadata_used_blocks gauge
dmcache_metadata_used_blocks{device="$dev"} $meta_used
# HELP dmcache_cache_used_blocks Cache blocks used
# TYPE dmcache_cache_used_blocks gauge
dmcache_cache_used_blocks{device="$dev"} $cache_used
# HELP dmcache_cache_total_blocks Total cache blocks
# TYPE dmcache_cache_total_blocks gauge
dmcache_cache_total_blocks{device="$dev"} $cache_total
# HELP dmcache_dirty_blocks Dirty blocks
# TYPE dmcache_dirty_blocks gauge
dmcache_dirty_blocks{device="$dev"} $dirty
# HELP dmcache_read_hits_total Read hits
# TYPE dmcache_read_hits_total counter
dmcache_read_hits_total{device="$dev"} $read_hits
# HELP dmcache_read_misses_total Read misses
# TYPE dmcache_read_misses_total counter
dmcache_read_misses_total{device="$dev"} $read_misses
# HELP dmcache_write_hits_total Write hits
# TYPE dmcache_write_hits_total counter
dmcache_write_hits_total{device="$dev"} $write_hits
# HELP dmcache_write_misses_total Write misses
# TYPE dmcache_write_misses_total counter
dmcache_write_misses_total{device="$dev"} $write_misses
METRICS
        fi
    fi
done > "$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
SCRIPT
chmod +x "$PERSISTENT_BIN/dmcache-metrics.sh"

echo "Creating systemd services..."
cat > "$PERSISTENT_SYSTEM/node_exporter.service" << 'SERVICE'
[Unit]
Description=Node Exporter
After=network.target

[Service]
Type=simple
ExecStart=/persistent/bin/node_exporter --collector.textfile.directory=/persistent/textfile_collector
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$PERSISTENT_SYSTEM/smartctl_exporter.service" << 'SERVICE'
[Unit]
Description=Smartctl Exporter
After=network.target

[Service]
Type=simple
ExecStart=/persistent/bin/smartctl_exporter
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$PERSISTENT_SYSTEM/restore.sh" << 'RESTORE'
#!/bin/bash
cp /persistent/system/node_exporter.service /etc/systemd/system/
cp /persistent/system/smartctl_exporter.service /etc/systemd/system/
echo "* * * * * root /persistent/bin/dmcache-metrics.sh" > /etc/cron.d/dmcache-metrics
systemctl daemon-reload
systemctl enable --now node_exporter smartctl_exporter
echo "Monitoring services restored"
RESTORE
chmod +x "$PERSISTENT_SYSTEM/restore.sh"

cp "$PERSISTENT_SYSTEM/node_exporter.service" /etc/systemd/system/
cp "$PERSISTENT_SYSTEM/smartctl_exporter.service" /etc/systemd/system/
echo "* * * * * root /persistent/bin/dmcache-metrics.sh" > /etc/cron.d/dmcache-metrics

"$PERSISTENT_BIN/dmcache-metrics.sh"

systemctl daemon-reload
systemctl enable --now node_exporter smartctl_exporter

echo ""
echo "=== Installation Complete ==="
echo "  node_exporter:     http://$(hostname -I | awk '{print $1}'):9100/metrics"
echo "  smartctl_exporter: http://$(hostname -I | awk '{print $1}'):9633/metrics"
echo ""
echo "After firmware upgrades, run: /persistent/system/restore.sh"
