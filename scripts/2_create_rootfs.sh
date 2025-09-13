#!/bin/bash

set -e

# 定义变量
ROOTFS_DIR="fedora-rootfs-aarch64"
RELEASEVER="42"
ARCH="aarch64"
ROOTFS_NAME="fedora-42-nabu-rootfs.tar.gz"

# 1. 创建 rootfs 目录
mkdir -p "$ROOTFS_DIR"

# 2. 初始化 DNF 环境并导入 COPR 仓库
dnf --install-root="$ROOTFS_DIR" --releasever="$RELEASEVER" --forcearch="$ARCH" --setopt=install_weak_deps=False -y \
    fedora-release \
    fedora-repos

# 启用所需的 COPR 仓库
dnf copr enable -y --root="$ROOTFS_DIR" --releasever="$RELEASEVER" --forcearch="$ARCH" jhuang6451/nabu_fedora_packages_uefi
dnf copr enable -y --root="$ROOTFS_DIR" --releasever="$RELEASEVER" --forcearch="$ARCH" onesaladleaf/pocketblue

# 3. 安装软件包
# 参考您提供的列表，安装基础环境、图形界面、高通组件和专用内核等
dnf --install-root="$ROOTFS_DIR" --releasever="$RELEASEVER" --forcearch="$ARCH" --setopt=install_weak_deps=False -y --exclude dracut-config-rescue install \
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
# 清理 dnf 缓存
dnf clean all --root="$ROOTFS_DIR" --releasever="$RELEASEVER"
# 移除 qemu-static
rm "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"

# 6. 压缩 rootfs
echo "Compressing rootfs..."
tar --xattrs -czpf "$ROOTFS_NAME" -C "$ROOTFS_DIR" .

echo "Rootfs created and compressed as $ROOTFS_NAME"