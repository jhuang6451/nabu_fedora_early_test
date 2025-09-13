#!/bin/bash

set -e

# 定义变量
ROOTFS_DIR="$PWD/fedora-rootfs-aarch64"
RELEASEVER="42"
ARCH="aarch64"
ROOTFS_NAME="fedora-42-nabu-rootfs.img" # 输出文件名
IMG_SIZE="8G" # 定义初始镜像大小，应确保足够容纳所有文件

# 1. 创建 rootfs 目录
mkdir -p "$ROOTFS_DIR"

# 启用所需的 COPR 仓库
dnf copr enable -y --installroot="$ROOTFS_DIR" jhuang6451/nabu_fedora_packages_uefi
dnf copr enable -y --installroot="$ROOTFS_DIR" onesaladleaf/pocketblue

# 3. 安装软件包
dnf install -y --installroot="$ROOTFS_DIR" --releasever="$RELEASEVER" --forcearch="$ARCH" --setopt=install_weak_deps=False --exclude dracut-config-rescue \
    @core \
    @hardware-support \
    @standard \
    @base-graphical \
    NetworkManager-tui \
    git \
    grubby \
    vim \
    glibc-langpack-en \
    btrfs-progs \
    systemd-resolved \
    grub2-efi-aa64 \
    grub2-efi-aa64-modules \
    qbootctl \
    tqftpserv \
    pd-mapper \
    rmtfs \
    qrtr \
    kernel-sm8150 \
    xiaomi-nabu-firmware \
    xiaomi-nabu-audio

# 4. Chroot 并配置系统
# 复制 qemu-aarch64-static 到 rootfs 中以执行 aarch64 程序
cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"

# 创建 qbootctl 服务文件
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
cat <<EOF > "${ROOTFS_DIR}/etc/systemd/system/qbootctl.service"
[Unit]
Description=Qualcomm boot slot ctrl mark boot successful

[Service]
ExecStart=/usr/bin/qbootctl -m
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Chroot 并启用服务
chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    systemctl enable tqftpserv.service
    systemctl enable rmtfs.service
    systemctl enable qbootctl.service
"

# 5. 清理 rootfs 以减小体积
# 清除dnf缓存
dnf clean all --installroot="$ROOTFS_DIR"
# 移除 qemu-static
rm "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"

# 6. 将 rootfs 打包为 img 文件
echo "Creating rootfs image..."
# 创建一个指定大小的空镜像文件
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
# 将镜像文件格式化为 ext4 文件系统
mkfs.ext4 "$ROOTFS_NAME"

# 创建一个临时挂载点
MOUNT_DIR=$(mktemp -d)
echo "Mounting image to $MOUNT_DIR"

# 挂载镜像文件
mount -o loop "$ROOTFS_NAME" "$MOUNT_DIR"

# 使用 rsync 将 rootfs 内容复制到镜像中，以保留所有权限和属性
echo "Copying rootfs contents to image..."
rsync -aHAXx --info=progress2 "$ROOTFS_DIR/" "$MOUNT_DIR/"

# 卸载镜像并清理临时目录
echo "Unmounting image..."
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo "Rootfs image created as $ROOTFS_NAME"

# 7. 最小化并压缩 img 文件
echo "Minimizing the image file..."

# 强制检查文件系统以确保其干净
e2fsck -f -y "$ROOTFS_NAME"

# 将文件系统大小调整为可能的最小值
resize2fs -M "$ROOTFS_NAME"

# 获取调整后文件系统的实际大小 (以字节为单位)
BLOCK_SIZE=$(tune2fs -l "$ROOTFS_NAME" | grep 'Block size' | awk '{print $3}')
BLOCK_COUNT=$(dumpe2fs -h "$ROOTFS_NAME" | grep 'Block count' | awk '{print $3}')
NEW_SIZE=$((BLOCK_SIZE * BLOCK_COUNT))

# 截断镜像文件以移除多余空间
truncate -s $NEW_SIZE "$ROOTFS_NAME"
echo "Image minimized to $NEW_SIZE bytes."