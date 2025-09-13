#!/bin/bash

set -e

# 定义变量
ESP_NAME="esp.img"
ESP_SIZE_MB=512
MNT_POINT="/mnt/esp"
ROOTFS_NAME="fedora-42-nabu-rootfs.tar.gz"
ROOTFS_DIR="fedora-rootfs-aarch64"

# 1. 解压 rootfs
echo "Extracting rootfs..."
mkdir -p "$ROOTFS_DIR"
tar -xzf "$ROOTFS_NAME" -C "$ROOTFS_DIR"

# 2. 创建一个 512MB 的空镜像文件
dd if=/dev/zero of="$ESP_NAME" bs=1M count="$ESP_SIZE_MB"

# 2. 格式化为 FAT32 文件系统
mkfs.vfat "$ESP_NAME"

# 4. 挂载镜像
mkdir -p "$MNT_POINT"
mount -o loop "$ESP_NAME" "$MNT_POINT"

# 5. 从 rootfs 复制内核和设备树文件
echo "Copying kernel and dtb..."
# grub.cfg 中引用的路径是 /fedora/Image，所以在这里创建 fedora 目录
mkdir -p "${MNT_POINT}/fedora"
# 从 rootfs 的 /boot 目录中找到最新的内核和对应的 dtb 文件
# 注意：这里假设内核版本号的格式，如果内核包更新，可能需要调整 find 命令
cp "${ROOTFS_DIR}/boot/Image"*.img "${MNT_POINT}/fedora/Image"
cp "${ROOTFS_DIR}/boot/dtb/sm8150-xiaomi-nabu.dtb" "${MNT_POINT}/fedora/sm8150-xiaomi-nabu.dtb"
echo "Kernel and dtb copied."

# 6. 安装 aarch64 GRUB 到 ESP
grub2-install \
    --target=arm64-efi \
    --efi-directory="$MNT_POINT" \
    --boot-directory="${MNT_POINT}/boot" \
    --removable

# 7. 创建 GRUB 配置文件
# 注意：这里的内核版本号和 root 分区需要根据实际情况调整
# `root=LABEL=fedora_root` 是一个示例，你需要确保你的 rootfs 分区有这个标签
# 或者使用 UUID (root=UUID=...)
cat <<EOF > "${MNT_POINT}/boot/grub2/grub.cfg"
set timeout=5
set default=0

menuentry 'Fedora 42 for Mi Pad 5 (nabu)' {
    # 内核 spec 文件中的 posttrans 脚本会将内核和 dtb 复制到 /boot/efi/fedora
    # 所以 ESP 挂载到 /boot/efi 时，路径是 /fedora/Image
    linux /fedora/Image root=LABEL=fedora_root rw quiet
    devicetree /fedora/sm8150-xiaomi-nabu.dtb
}
EOF

# 8. 卸载镜像
umount "$MNT_POINT"
rmdir "$MNT_POINT"

echo "ESP image created as $ESP_NAME"
