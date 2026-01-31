#!/bin/bash
# UNAS Pro Tools - RustFS Installer
# Installs RustFS S3-compatible storage with OpenTelemetry metrics
set -e

PERSISTENT_BIN="/persistent/bin"
PERSISTENT_SYSTEM="/persistent/system"

RUSTFS_VERSION="1.0.0-alpha.82"
OTEL_VERSION="0.144.0"

echo "=== UNAS Pro Tools - RustFS Installer ==="
echo ""

if [ ! -d "/persistent" ]; then
    echo "ERROR: /persistent directory not found. Are you running on UNAS Pro?"
    exit 1
fi

mkdir -p "$PERSISTENT_BIN" "$PERSISTENT_SYSTEM"

ARCH=$(uname -m)
case $ARCH in
    aarch64) ARCH_SUFFIX="arm64"; RUSTFS_ARCH="aarch64" ;;
    x86_64)  ARCH_SUFFIX="amd64"; RUSTFS_ARCH="x86_64" ;;
    *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Find data volume
DATA_VOLUME=$(ls -d /volume/*/ 2>/dev/null | head -1)
if [ -z "$DATA_VOLUME" ]; then
    echo "ERROR: No data volume found in /volume/"
    exit 1
fi
RUSTFS_DATA="${DATA_VOLUME}.srv/rustfs-data"
mkdir -p "$RUSTFS_DATA"

echo "Installing RustFS v${RUSTFS_VERSION}..."
cd /tmp
curl -sLO "https://github.com/rustfs/rustfs/releases/download/${RUSTFS_VERSION}/rustfs-linux-${RUSTFS_ARCH}-gnu-latest.zip"
python3 -c "import zipfile; zipfile.ZipFile('rustfs-linux-${RUSTFS_ARCH}-gnu-latest.zip').extractall('.')"
chmod +x rustfs
mv rustfs "$PERSISTENT_BIN/"
rm -f rustfs-linux-${RUSTFS_ARCH}-gnu-latest.zip

echo "Installing OpenTelemetry Collector v${OTEL_VERSION}..."
curl -sLO "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_${ARCH_SUFFIX}.tar.gz"
tar xzf "otelcol-contrib_${OTEL_VERSION}_linux_${ARCH_SUFFIX}.tar.gz"
mv otelcol-contrib "$PERSISTENT_BIN/"
rm -f "otelcol-contrib_${OTEL_VERSION}_linux_${ARCH_SUFFIX}.tar.gz"

# Generate credentials
ACCESS_KEY=$(openssl rand -hex 10)
SECRET_KEY=$(openssl rand -hex 20)

cat > "$PERSISTENT_SYSTEM/rustfs.credentials" << CREDS
# RustFS S3 Credentials
AWS_ACCESS_KEY_ID=$ACCESS_KEY
AWS_SECRET_ACCESS_KEY=$SECRET_KEY
ENDPOINT_URL=http://$(hostname -I | awk '{print $1}'):9000
CONSOLE_URL=http://$(hostname -I | awk '{print $1}'):9001
CREDS
chmod 600 "$PERSISTENT_SYSTEM/rustfs.credentials"

echo "Creating OTEL collector config..."
cat > "$PERSISTENT_SYSTEM/otel-collector.yaml" << 'CONFIG'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 10s

exporters:
  prometheus:
    endpoint: 0.0.0.0:8889
    namespace: rustfs
    send_timestamps: true
    metric_expiration: 5m
  nop: {}

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [prometheus]
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [nop]
    logs:
      receivers: [otlp]
      processors: [batch]
      exporters: [nop]
CONFIG

echo "Creating systemd services..."
cat > "$PERSISTENT_SYSTEM/otel-collector.service" << 'SERVICE'
[Unit]
Description=OpenTelemetry Collector
After=network.target

[Service]
Type=simple
ExecStart=/persistent/bin/otelcol-contrib --config /persistent/system/otel-collector.yaml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

cat > "$PERSISTENT_SYSTEM/rustfs.service" << SERVICE
[Unit]
Description=RustFS S3-compatible Object Storage
After=network.target otel-collector.service
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="RUSTFS_ACCESS_KEY=$ACCESS_KEY"
Environment="RUSTFS_SECRET_KEY=$SECRET_KEY"
ExecStart=/persistent/bin/rustfs --address :9000 --console-enable --console-address :9001 --obs-endpoint http://127.0.0.1:4318 $RUSTFS_DATA
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE

cp "$PERSISTENT_SYSTEM/otel-collector.service" /etc/systemd/system/
cp "$PERSISTENT_SYSTEM/rustfs.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now otel-collector rustfs

echo ""
echo "=== RustFS Installation Complete ==="
echo ""
echo "S3 API:      http://$(hostname -I | awk '{print $1}'):9000"
echo "Console:     http://$(hostname -I | awk '{print $1}'):9001/rustfs/console/index.html"
echo "Metrics:     http://$(hostname -I | awk '{print $1}'):8889/metrics"
echo ""
echo "Credentials saved to: $PERSISTENT_SYSTEM/rustfs.credentials"
cat "$PERSISTENT_SYSTEM/rustfs.credentials"
