#!/bin/bash
# Launch the custom ISO in QEMU — fast boot + network
#   -enable-kvm  → hardware acceleration
#   -nic user    → user-mode networking (for Firefox)
#   -vga std -device isa-debug-exit,iobase=0xf4,iosize=0x04 -serial file:ttyS0.log     → VBE graphics
#   -boot order=d,strict=on → boot CD first, skip iPXE delay

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="$SCRIPT_DIR/custom.iso"

if [ ! -f "$ISO" ]; then
    echo "ERROR: $ISO not found. Run build_iso.sh first."
    exit 1
fi

exec qemu-system-x86_64 \
    -cdrom "$ISO" \
    -m 3072 \
    -vga std \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -serial file:serial.log \
    -boot order=d,strict=on \
    -nic user,model=e1000 \
    -enable-kvm \
    -cpu host \
    "$@"
