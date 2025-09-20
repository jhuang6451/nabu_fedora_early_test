#!/bin/bash
set -e

ESP_NAME="esp.img"
ESP_SIZE_MB=512
ROOTFS_NAME="fedora-42-nabu-rootfs.img"
ROOTFS_MNT_POINT=$(mktemp -d)
ESP_MNT_POINT=$(mktemp -d)

cleanup() {
    umount "$ESP_MNT_POINT" 2>/dev/null || true
    umount "$ROOTFS_MNT_POINT" 2>/dev/null || true
    rmdir "$ESP_MNT_POINT" 2>/dev/null || true
    rmdir "$ROOTFS_MNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# 1. 创建并挂载 ESP
fallocate -l "${ESP_SIZE_MB}M" "$ESP_NAME"
mkfs.vfat -F 32 -n "ESP" "$ESP_NAME"
mount -o loop "$ESP_NAME" "$ESP_MNT_POINT"

# 2. 以只读方式挂载 Rootfs
mount -o loop,ro "$ROOTFS_NAME" "$ROOTFS_MNT_POINT"

# 3. 复制已经由dracut在rootfs中生成好的UKI文件
echo "Copying pre-generated UKI from rootfs to ESP..."
# UKI默认生成路径可能不同，需要确认
# Fedora 39+ 的路径通常是 /boot/efi/EFI/Linux/
UKI_SOURCE_DIR="${ROOTFS_MNT_POINT}/boot/efi/EFI/Linux"
if [ ! -d "$UKI_SOURCE_DIR" ] || [ -z "$(ls -A $UKI_SOURCE_DIR/*.efi)" ]; then
    echo "ERROR: No UKI found in '$UKI_SOURCE_DIR'. Check if dracut ran correctly." >&2
    exit 1
fi

mkdir -p "${ESP_MNT_POINT}/EFI/fedora/"
# 找到最新的UKI文件并复制
UKI_FILE=$(find "$UKI_SOURCE_DIR" -name "*.efi" -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2-)
cp "$UKI_FILE" "${ESP_MNT_POINT}/EFI/fedora/fedora.efi"

echo "SUCCESS: ESP image created with the automatically generated UKI."