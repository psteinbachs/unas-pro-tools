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
# dm-cache metrics exporter for Prometheus node_exporter textfile collector
set -euo pipefail

OUTPUT_FILE="/persistent/textfile_collector/dmcache.prom"
TEMP_FILE="${OUTPUT_FILE}.tmp"

DMCACHE_OUTPUT=$(dmsetup status --target cache 2>/dev/null || true)

if [[ -z "$DMCACHE_OUTPUT" ]]; then
    echo "# No dm-cache devices found" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$OUTPUT_FILE"
    exit 0
fi

cat > "$TEMP_FILE" << 'EOF'
# HELP dmcache_cache_used_blocks Number of cache blocks in use
# TYPE dmcache_cache_used_blocks gauge
# HELP dmcache_cache_total_blocks Total number of cache blocks
# TYPE dmcache_cache_total_blocks gauge
# HELP dmcache_read_hits_total Total read hits
# TYPE dmcache_read_hits_total counter
# HELP dmcache_read_misses_total Total read misses
# TYPE dmcache_read_misses_total counter
# HELP dmcache_write_hits_total Total write hits
# TYPE dmcache_write_hits_total counter
# HELP dmcache_write_misses_total Total write misses
# TYPE dmcache_write_misses_total counter
# HELP dmcache_demotions_total Total demotions from cache
# TYPE dmcache_demotions_total counter
# HELP dmcache_promotions_total Total promotions to cache
# TYPE dmcache_promotions_total counter
# HELP dmcache_dirty_blocks Number of dirty blocks in cache
# TYPE dmcache_dirty_blocks gauge
# HELP dmcache_hit_ratio Cache hit ratio (0-1)
# TYPE dmcache_hit_ratio gauge
EOF

echo "$DMCACHE_OUTPUT" | while IFS= read -r line; do
    device=$(echo "$line" | cut -d: -f1)
    fields=$(echo "$line" | cut -d: -f2-)

    # dm-cache status format:
    # start len cache meta_blk_sz used_meta/total_meta cache_blk_sz used_cache/total_cache
    # read_hits read_misses write_hits write_misses demotions promotions dirty ...
    read -r start length target_type meta_blk_sz meta_blocks cache_blk_sz cache_blocks \
         read_hits read_misses write_hits write_misses demotions promotions dirty rest <<< "$fields"

    [[ "$target_type" != "cache" ]] && continue

    cache_used=$(echo "$cache_blocks" | cut -d/ -f1)
    cache_total=$(echo "$cache_blocks" | cut -d/ -f2)

    total_ops=$((read_hits + read_misses + write_hits + write_misses))
    total_hits=$((read_hits + write_hits))
    if [[ $total_ops -gt 0 ]]; then
        hit_ratio=$(awk "BEGIN {printf \"%.6f\", $total_hits / $total_ops}")
    else
        hit_ratio="0"
    fi

    cat >> "$TEMP_FILE" << METRICS
dmcache_cache_used_blocks{device="$device"} $cache_used
dmcache_cache_total_blocks{device="$device"} $cache_total
dmcache_read_hits_total{device="$device"} $read_hits
dmcache_read_misses_total{device="$device"} $read_misses
dmcache_write_hits_total{device="$device"} $write_hits
dmcache_write_misses_total{device="$device"} $write_misses
dmcache_demotions_total{device="$device"} $demotions
dmcache_promotions_total{device="$device"} $promotions
dmcache_dirty_blocks{device="$device"} $dirty
dmcache_hit_ratio{device="$device"} $hit_ratio
METRICS
done

mv "$TEMP_FILE" "$OUTPUT_FILE"
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
