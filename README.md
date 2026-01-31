# UNAS Pro Tools

Observability and S3 storage tools for Ubiquiti UNAS Pro 8.

> **Warning**: These tools are unofficial and may void your warranty. Use at your own risk.

## Features

- **Monitoring Stack**: Prometheus exporters for system metrics, SMART data, and dm-cache stats
- **Grafana Dashboards**: Pre-built dashboards for storage monitoring
- **RustFS**: S3-compatible object storage (Apache 2.0 licensed alternative to MinIO)

## Quick Start

SSH into your UNAS Pro 8 and run:

### Monitoring Only

```bash
curl -sL https://raw.githubusercontent.com/psteinbachs/unas-pro-tools/main/scripts/install-monitoring.sh | bash
```

### RustFS + Monitoring

```bash
curl -sL https://raw.githubusercontent.com/psteinbachs/unas-pro-tools/main/scripts/install-all.sh | bash
```

## What Gets Installed

All files are installed to `/persistent/` to survive firmware upgrades.

### Binaries (`/persistent/bin/`)
- `node_exporter` - System metrics (CPU, memory, disk, network, btrfs)
- `smartctl_exporter` - SMART drive health data
- `dmcache-metrics.sh` - dm-cache stats collector (hit ratio, dirty blocks, promotions/demotions)
- `otelcol-contrib` - OpenTelemetry collector (for RustFS metrics)
- `rustfs` - S3-compatible object storage

### Services
| Service | Port | Description |
|---------|------|-------------|
| node_exporter | 9100 | System metrics |
| smartctl_exporter | 9633 | SMART data |
| otel-collector | 4318/8889 | OTLP receiver / Prometheus metrics |
| rustfs | 9000/9001 | S3 API / Web console |

### Grafana Dashboards
- **UNAS Pro 8 - Storage**: dm-cache hit ratio, dirty blocks, HDD/NVMe health, pool stats
- **RustFS**: S3 API metrics, request latency, throughput

## Import Dashboards

The `dashboards/` directory contains Grafana dashboards for monitoring.

**Via Grafana UI:** Dashboards → Import → Upload JSON file

- `unas-storage.json` - dm-cache stats, HDD/NVMe health, btrfs pool stats
- `rustfs.json` - S3 API metrics, request latency, throughput

**Via API:**
```bash
curl -u admin:password -X POST http://your-grafana:3000/api/dashboards/db \
  -H "Content-Type: application/json" -d @dashboards/unas-storage.json

curl -u admin:password -X POST http://your-grafana:3000/api/dashboards/db \
  -H "Content-Type: application/json" -d @dashboards/rustfs.json
```

## Post-Firmware Upgrade

Run the restore script after any firmware upgrade:

```bash
/persistent/system/restore.sh
```

## Prometheus Scrape Config

Add to your Prometheus configuration:

```yaml
scrape_configs:
  - job_name: 'unas-node'
    static_configs:
      - targets: ['<UNAS_IP>:9100']
  - job_name: 'unas-smart'
    static_configs:
      - targets: ['<UNAS_IP>:9633']
  - job_name: 'unas-rustfs'
    static_configs:
      - targets: ['<UNAS_IP>:8889']
```

## Requirements

- UNAS Pro 8 with SSH access enabled
- External Prometheus + Grafana instance for dashboards

## License

MIT License - See [LICENSE](LICENSE)

## Credits

- [RustFS](https://github.com/rustfs/rustfs) - Apache 2.0 licensed S3 storage
- [Prometheus](https://prometheus.io/) exporters
- Inspired by debugging Ubiquiti's storage stack
