#!/bin/bash
# ==============================================================================
# 3_create_esp.sh (v2.3 - Robust UKI Discovery)
#
# 功能:
#   1. 创建并格式化 ESP 镜像。
#   2. 挂载 rootfs 镜像。
#   3. 在 rootfs 的 /boot 目录中动态搜索最新的 UKI (.efi) 文件。
#   4. 将找到的 UKI 复制到 ESP 分区中。
# ==============================================================================

set -e
set -u
set -o pipefail

# --- 变量定义 ---
ESP_NAME="esp.img"
ESP_SIZE_MB=512
ROOTFS_NAME="fedora-42-nabu-rootfs.img"
ROOTFS_MNT_POINT=$(mktemp -d)
ESP_MNT_POINT=$(mktemp -d)

cleanup() {
    echo "INFO: Performing cleanup..."
    umount -l "$ESP_MNT_POINT" 2>/dev/null || true
    umount -l "$ROOTFS_MNT_POINT" 2>/dev/null || true
    rmdir "$ESP_MNT_POINT" 2>/dev/null || true
    rmdir "$ROOTFS_MNT_POINT" 2>/dev/null || true
    echo "INFO: Cleanup complete."
}
trap cleanup EXIT

# 1. 创建并挂载 ESP
echo "INFO: Creating ESP image '$ESP_NAME'..."
fallocate -l "${ESP_SIZE_MB}M" "$ESP_NAME"
mkfs.vfat -F 32 -n "ESP" "$ESP_NAME"
mount -o loop "$ESP_NAME" "$ESP_MNT_POINT"
echo "INFO: ESP mounted at '$ESP_MNT_POINT'."

# 2. 以只读方式挂载 Rootfs
echo "INFO: Mounting rootfs image '$ROOTFS_NAME'..."
mount -o loop,ro "$ROOTFS_NAME" "$ROOTFS_MNT_POINT"
echo "INFO: Rootfs mounted at '$ROOTFS_MNT_POINT'."

# 3. 动态搜索 UKI 文件并复制
echo "INFO: Searching for the latest UKI file in rootfs..."

# 在 /boot 目录下搜索所有 .efi 文件，并根据修改时间找到最新的一个
UKI_FILE_PATH=$(find "${ROOTFS_MNT_POINT}/boot" -name "*.efi" -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2-)

if [ -z "$UKI_FILE_PATH" ]; then
    echo "ERROR: No UKI (.efi file) found anywhere inside the '/boot' directory of the rootfs." >&2
    echo "ERROR: Please check the logs of '2_create_rootfs.sh' to ensure dracut ran successfully." >&2
    exit 1
fi

echo "INFO: Found UKI at: '$UKI_FILE_PATH'"

# 准备 ESP 中的目标目录
DESTINATION_DIR="${ESP_MNT_POINT}/EFI/fedora"
DESTINATION_FILE="${DESTINATION_DIR}/fedora.efi"
mkdir -p "$DESTINATION_DIR"

# 复制文件
echo "INFO: Copying UKI to ESP as '$DESTINATION_FILE'..."
cp "$UKI_FILE_PATH" "$DESTINATION_FILE"

echo "SUCCESS: ESP image '$ESP_NAME' created with the discovered UKI."
exit 0