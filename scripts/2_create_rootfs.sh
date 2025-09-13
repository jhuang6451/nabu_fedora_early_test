#!/bin/bash

set -e

# 定义变量
ROOTFS_DIR="$PWD/fedora-rootfs-aarch64"
RELEASEVER="42"
ARCH="aarch64"
ROOTFS_NAME="fedora-42-nabu-rootfs.img"
IMG_SIZE="8G"

# 1. 创建 rootfs 目录
mkdir -p "$ROOTFS_DIR"

# 2. 使用 Metalink 引导基础仓库
echo "Bootstrapping Fedora repositories for $ARCH..."
TEMP_REPO_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_REPO_DIR"' EXIT
cat <<EOF > "${TEMP_REPO_DIR}/temp-fedora.repo"
[temp-fedora]
name=Temporary Fedora $RELEASEVER - $ARCH
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$RELEASEVER&arch=$ARCH
enabled=1
gpgcheck=0
skip_if_unavailable=False
EOF
dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" \
    --setopt="reposdir=${TEMP_REPO_DIR}" \
    --releasever="$RELEASEVER" \
    fedora-repos

# 3. 安装所有软件包
echo "Installing all packages into rootfs..."
dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" --releasever="$RELEASEVER" \
    --repofrompath="jhuang6451-copr,https://download.copr.fedorainfracloud.org/results/jhuang6451/nabu_fedora_packages_uefi/fedora-$RELEASEVER-$ARCH/" \
    --repofrompath="onesaladleaf-copr,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-$RELEASEVER-$ARCH/" \
    --nogpgcheck \
    --setopt=install_weak_deps=False --exclude dracut-config-rescue \
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
# 创建服务文件
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

# 因为是原生环境，一个简单的 chroot 就可以完美工作
chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    systemctl enable tqftpserv.service
    systemctl enable rmtfs.service
    systemctl enable qbootctl.service
"

# 5. 清理 rootfs
dnf clean all --installroot="$ROOTFS_DIR"

# 6. 将 rootfs 打包为 img 文件
echo "Creating rootfs image..."
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
mkfs.ext4 -F "$ROOTFS_NAME"
MOUNT_DIR=$(mktemp -d)
mount -o loop "$ROOTFS_NAME" "$MOUNT_DIR"
echo "Copying rootfs contents to image..."
rsync -aHAXx --info=progress2 "$ROOTFS_DIR/" "$MOUNT_DIR/"
echo "Unmounting image..."
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
echo "Rootfs image created as $ROOTFS_NAME"

# 7. 最小化并压缩 img 文件
echo "Minimizing the image file..."
e2fsck -f -y "$ROOTFS_NAME"
resize2fs -M "$ROOTFS_NAME"
BLOCK_SIZE=$(tune2fs -l "$ROOTFS_NAME" | grep 'Block size' | awk '{print $3}')
BLOCK_COUNT=$(dumpe2fs -h "$ROOTFS_NAME" | grep 'Block count' | awk '{print $3}')
NEW_SIZE=$((BLOCK_SIZE * BLOCK_COUNT))
truncate -s $NEW_SIZE "$ROOTFS_NAME"
echo "Image minimized to $NEW_SIZE bytes."