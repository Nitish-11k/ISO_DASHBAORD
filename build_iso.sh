#!/bin/bash
#
# build_iso.sh — Build the Custom Python Dashboard ISO (fakeroot fix + Verification)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO_ROOT="$SCRIPT_DIR/iso_root"
OUTPUT_ISO="$SCRIPT_DIR/custom.iso"

echo "=== Building Custom Dashboard ISO ==="

# 1. Remaster Tiny Core
echo "[1/3] Running remaster_tc.sh (with fakeroot)..."
if command -v fakeroot >/dev/null; then
    fakeroot bash "$SCRIPT_DIR/remaster_tc.sh"
else
    echo "ERROR: fakeroot is required for correct permissions on /dev nodes!"
    exit 1
fi

# 2. Verify ISO tree and vital extensions
echo "[2/3] Verifying ISO tree..."
REQUIRED_FILES="
boot/vmlinuz64
boot/core_custom.gz
boot/grub/grub.cfg
"

for f in $REQUIRED_FILES; do
    if [ ! -f "$ISO_ROOT/$f" ]; then
        echo "ERROR: Missing $f in iso_root!"
        exit 1
    fi
done

# 3. Build the ISO with grub-mkrescue
echo "[3/3] Building ISO with grub-mkrescue..."
rm -f "$OUTPUT_ISO"
grub-mkrescue -o "$OUTPUT_ISO" "$ISO_ROOT" -- \
    -volid "CUSTOM_ISO" 2>&1 | tail -5

echo ""
echo "=== BUILD COMPLETE ==="
echo "ISO: $OUTPUT_ISO"
echo "Size: $(du -sh "$OUTPUT_ISO" | cut -f1)"
echo ""
echo "To test in QEMU:"
echo "  bash run_qemu.sh"
echo ""
