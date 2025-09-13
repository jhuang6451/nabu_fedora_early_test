#!/bin/bash

set -e

# 定义变量
ESP_NAME="esp.img"
ESP_SIZE_MB=512
ESP_MNT_POINT="/mnt/esp"
# 将 rootfs 文件名从 .tar.gz 修改为 .img
ROOTFS_NAME="fedora-42-nabu-rootfs.img"
# 为 rootfs 镜像创建一个挂载点
ROOTFS_MNT_POINT="/mnt/rootfs"


# 1. 挂载 rootfs 镜像以访问其内容
echo "Mounting rootfs image..."
mkdir -p "$ROOTFS_MNT_POINT"
# 将 rootfs 镜像以 loop 方式挂载
mount -o loop "$ROOTFS_NAME" "$ROOTFS_MNT_POINT"


# 2. 创建一个 512MB 的空 ESP 镜像文件
echo "Creating ESP image..."
dd if=/dev/zero of="$ESP_NAME" bs=1M count="$ESP_SIZE_MB"


# 3. 格式化为 FAT32 文件系统
mkfs.vfat "$ESP_NAME"


# 4. 挂载 ESP 镜像
echo "Mounting ESP image..."
mkdir -p "$ESP_MNT_POINT"
mount -o loop "$ESP_NAME" "$ESP_MNT_POINT"


# 5. 从已挂载的 rootfs 镜像中复制内核和设备树文件
echo "Copying kernel and dtb..."
# grub.cfg 中引用的路径是 /fedora/，所以在这里创建 fedora 目录
mkdir -p "${ESP_MNT_POINT}/fedora"
# 从 rootfs 挂载点的 /boot 目录中找到最新的内核和对应的 dtb 文件
cp "${ROOTFS_MNT_POINT}/boot/Image"*.img "${ESP_MNT_POINT}/fedora/Image"
cp "${ROOTFS_MNT_POINT}/boot/dtb/sm8150-xiaomi-nabu.dtb" "${ESP_MNT_POINT}/fedora/sm8150-xiaomi-nabu.dtb"
echo "Kernel and dtb copied."


# 6. 安装 aarch64 GRUB 到 ESP
echo "Installing GRUB..."
grub2-install \
    --target=arm64-efi \
    --efi-directory="$ESP_MNT_POINT" \
    --boot-directory="${ESP_MNT_POINT}/boot" \
    --removable


# 7. 创建 GRUB 配置文件
echo "Creating grub.cfg..."
# 注意：这里的内核版本号和 root 分区需要根据实际情况调整
# `root=LABEL=fedora_root` 是一个示例，你需要确保你的 rootfs 分区有这个标签
# 或者使用 UUID (root=UUID=...)
cat <<EOF > "${ESP_MNT_POINT}/boot/grub2/grub.cfg"
set timeout=5
set default=0

menuentry 'Fedora 42 for Mi Pad 5 (nabu)' {
    # 路径是相对于 ESP 分区的根目录
    linux /fedora/Image root=LABEL=fedora_root rw quiet
    devicetree /fedora/sm8150-xiaomi-nabu.dtb
}
EOF


# 8. 卸载所有镜像
echo "Unmounting images..."
umount "$ESP_MNT_POINT"
umount "$ROOTFS_MNT_POINT"
rmdir "$ESP_MNT_POINT"
rmdir "$ROOTFS_MNT_POINT"

echo "ESP image created successfully as $ESP_NAME"