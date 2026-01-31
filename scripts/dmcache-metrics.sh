#!/bin/bash
# dm-cache metrics exporter for Prometheus node_exporter textfile collector
# Writes metrics to /persistent/metrics/dmcache.prom

set -euo pipefail

OUTPUT_DIR="/persistent/metrics"
OUTPUT_FILE="${OUTPUT_DIR}/dmcache.prom"
TEMP_FILE="${OUTPUT_FILE}.tmp"

mkdir -p "$OUTPUT_DIR"

# Get dm-cache status
DMCACHE_OUTPUT=$(dmsetup status --target cache 2>/dev/null || true)

if [[ -z "$DMCACHE_OUTPUT" ]]; then
    # No dm-cache devices found
    echo "# No dm-cache devices found" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$OUTPUT_FILE"
    exit 0
fi

cat > "$TEMP_FILE" << 'EOF'
# HELP dmcache_metadata_block_size_sectors Metadata block size in sectors
# TYPE dmcache_metadata_block_size_sectors gauge
# HELP dmcache_metadata_used_blocks Number of metadata blocks in use
# TYPE dmcache_metadata_used_blocks gauge
# HELP dmcache_metadata_total_blocks Total number of metadata blocks
# TYPE dmcache_metadata_total_blocks gauge
# HELP dmcache_cache_block_size_sectors Cache block size in sectors
# TYPE dmcache_cache_block_size_sectors gauge
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
# HELP dmcache_cache_size_bytes Total cache size in bytes
# TYPE dmcache_cache_size_bytes gauge
# HELP dmcache_cache_used_bytes Used cache size in bytes
# TYPE dmcache_cache_used_bytes gauge
# HELP dmcache_hit_ratio Cache hit ratio (0-1)
# TYPE dmcache_hit_ratio gauge
EOF

echo "$DMCACHE_OUTPUT" | while IFS= read -r line; do
    # Parse: device: start length cache metadata_block_size used_meta/total_meta cache_block_size used_cache/total_cache read_hits read_misses write_hits write_misses demotions promotions dirty ...
    device=$(echo "$line" | cut -d: -f1)
    fields=$(echo "$line" | cut -d: -f2-)

    # Extract fields (space separated after the colon)
    read -r start length target_type metadata_block_size meta_blocks cache_block_size cache_blocks \
         read_hits read_misses write_hits write_misses demotions promotions dirty rest <<< "$fields"

    # Skip if not a cache target
    [[ "$target_type" != "cache" ]] && continue

    # Parse used/total blocks
    meta_used=$(echo "$meta_blocks" | cut -d/ -f1)
    meta_total=$(echo "$meta_blocks" | cut -d/ -f2)
    cache_used=$(echo "$cache_blocks" | cut -d/ -f1)
    cache_total=$(echo "$cache_blocks" | cut -d/ -f2)

    # Calculate derived metrics
    # Cache block size is in sectors (512 bytes each)
    cache_block_bytes=$((cache_block_size * 512))
    cache_size_bytes=$((cache_total * cache_block_bytes))
    cache_used_bytes=$((cache_used * cache_block_bytes))

    # Calculate hit ratio
    total_reads=$((read_hits + read_misses))
    total_writes=$((write_hits + write_misses))
    total_ops=$((total_reads + total_writes))
    total_hits=$((read_hits + write_hits))

    if [[ $total_ops -gt 0 ]]; then
        # Use awk for floating point
        hit_ratio=$(awk "BEGIN {printf \"%.6f\", $total_hits / $total_ops}")
    else
        hit_ratio="0"
    fi

    # Output metrics with device label
    cat >> "$TEMP_FILE" << METRICS
dmcache_metadata_block_size_sectors{device="$device"} $metadata_block_size
dmcache_metadata_used_blocks{device="$device"} $meta_used
dmcache_metadata_total_blocks{device="$device"} $meta_total
dmcache_cache_block_size_sectors{device="$device"} $cache_block_size
dmcache_cache_used_blocks{device="$device"} $cache_used
dmcache_cache_total_blocks{device="$device"} $cache_total
dmcache_read_hits_total{device="$device"} $read_hits
dmcache_read_misses_total{device="$device"} $read_misses
dmcache_write_hits_total{device="$device"} $write_hits
dmcache_write_misses_total{device="$device"} $write_misses
dmcache_demotions_total{device="$device"} $demotions
dmcache_promotions_total{device="$device"} $promotions
dmcache_dirty_blocks{device="$device"} $dirty
dmcache_cache_size_bytes{device="$device"} $cache_size_bytes
dmcache_cache_used_bytes{device="$device"} $cache_used_bytes
dmcache_hit_ratio{device="$device"} $hit_ratio
METRICS

done

# Atomic move
mv "$TEMP_FILE" "$OUTPUT_FILE"
