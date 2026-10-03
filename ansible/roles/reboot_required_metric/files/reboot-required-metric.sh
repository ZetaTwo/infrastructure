#!/bin/sh
# Exposes /run/reboot-required (set by apt when an upgrade needs a reboot)
# as a node_exporter textfile metric (k8s/monitoring/node-exporter.yaml).
set -eu
dir=/var/lib/node_exporter/textfile
value=0
[ -f /run/reboot-required ] && value=1
# Write-then-rename so node_exporter never reads a partial file.
cat > "$dir/reboot_required.prom.$$" <<METRIC
# HELP node_reboot_required Whether a reboot is pending after package upgrades.
# TYPE node_reboot_required gauge
node_reboot_required $value
METRIC
mv "$dir/reboot_required.prom.$$" "$dir/reboot_required.prom"
