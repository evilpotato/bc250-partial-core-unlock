#!/bin/bash
# Build bc250-acpi.cpio: an uncompressed early-initrd cpio carrying SSDT-CST + SSDT-PST from
# https://github.com/mendesrr/bc250-acpi-fix-updated-8c (not redistributed here — no license).
# They add _CST (C1/C2/C3) and _PSS (8 P-states) to \_PR.P000-P00F; the stock firmware's CPU SSDT
# targets \_PR.C000-C00F, which doesn't exist, so without this no CPU has C-states or cpufreq.
# Needs: git, iasl (acpica-tools), cpio. The .aml is rebuilt from the .dsl sources you can read.
set -euo pipefail
REV=${1:-83686c4}                 # commit reviewed for this repo; pass another to override
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
git clone -q https://github.com/mendesrr/bc250-acpi-fix-updated-8c "$W/src"
git -C "$W/src" checkout -q "$REV"
mkdir -p "$W/cpio/kernel/firmware/acpi"
for t in SSDT-CST SSDT-PST; do
    iasl -p "$W/cpio/kernel/firmware/acpi/$t" "$W/src/$t.dsl" | grep -E 'Compilation|Error'
done
(cd "$W/cpio" && find kernel | LC_ALL=C sort | cpio -o -H newc --quiet -R 0:0) > bc250-acpi.cpio
cpio -t < bc250-acpi.cpio 2>/dev/null
sha256sum bc250-acpi.cpio
