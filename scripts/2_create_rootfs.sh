#!/bin/bash

set -e

# 定义变量
ROOTFS_DIR="$PWD/fedora-rootfs-aarch64"
RELEASEVER="42"
ARCH="aarch64"
ROOTFS_NAME="fedora-42-nabu-rootfs.img"
IMG_SIZE="8G"

# Mount chroot filesystems 函数
mount_chroot_fs() {
    echo "Mounting chroot filesystems into $ROOTFS_DIR..."
    mkdir -p "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/dev/pts"
    # Bind mount essential host filesystems
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount -t devpts devpts "$ROOTFS_DIR/dev/pts" # Mount a new devpts instance for chroot
    # Copy resolv.conf to enable network resolution inside chroot
    cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
}

# Unmount chroot filesystems 函数
umount_chroot_fs() {
    echo "Unmounting chroot filesystems from $ROOTFS_DIR..."
    # Unmount in reverse order
    umount "$ROOTFS_DIR/dev/pts" || true # Use || true in case it wasn't mounted by mount -t devpts
    umount "$ROOTFS_DIR/dev"
    umount "$ROOTFS_DIR/sys"
    umount "$ROOTFS_DIR/proc"
    # Remove copied resolv.conf
    rm -f "$ROOTFS_DIR/etc/resolv.conf"
}

# 1. 创建 rootfs 目录
echo "Creating rootfs directory: $ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 2. 使用 Metalink 引导基础仓库
# 此步骤通常不依赖复杂的 /proc /sys 访问，因此仍使用 --installroot
echo "Bootstrapping Fedora repositories for $ARCH..."
TEMP_REPO_DIR=$(mktemp -d)
# 确保临时仓库目录在脚本退出时被清理
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
rm -rf -- "$TEMP_REPO_DIR" # 清理临时仓库目录

# 3. 安装所有软件包 (在 chroot 环境中执行)
echo "Installing all packages into rootfs via chroot..."
mount_chroot_fs # 挂载 chroot 所需的文件系统

# 在 chroot 内部执行 dnf install 命令
chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    # 从 chroot 内部运行 dnf，不再需要 --installroot 或 --forcearch
    echo \"Running dnf install inside chroot...\"
    dnf install -y --releasever=$RELEASEVER \
        --repofrompath=\"jhuang6451-copr,https://download.copr.fedorainfracloud.org/results/jhuang6451/nabu_fedora_packages_uefi/fedora-$RELEASEVER-$ARCH/\" \
        --repofrompath=\"onesaladleaf-copr,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-$RELEASEVER-$ARCH/\" \
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
    echo \"dnf install inside chroot completed.\"
"
umount_chroot_fs # 卸载 chroot 所需的文件系统

# 4. Chroot 并配置系统
# 创建服务文件 (此步骤在宿主系统上进行，只是创建文件)
echo "Creating qbootctl.service file..."
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

# 配置服务 (此步骤需要在 chroot 环境中进行，因为涉及到 systemctl enable)
echo "Chrooting into rootfs for system configuration (enabling services)..."
mount_chroot_fs # 重新挂载 chroot 所需的文件系统

chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    echo \"Running systemctl enable inside chroot...\"
    systemctl enable tqftpserv.service
    systemctl enable rmtfs.service
    systemctl enable qbootctl.service
    echo \"systemctl enable inside chroot completed.\"
"
umount_chroot_fs # 卸载 chroot 所需的文件系统

# 5. 清理 rootfs
echo "Cleaning up dnf cache in rootfs..."
# DNF clean all 可以在宿主系统上使用 --installroot 进行清理
dnf clean all --installroot="$ROOTFS_DIR"

# 6. 将 rootfs 打包为 img 文件
echo "Creating rootfs image: $ROOTFS_NAME (size: $IMG_SIZE)..."
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
mkfs.ext4 -F "$ROOTFS_NAME"
MOUNT_DIR=$(mktemp -d)
trap 'rm -rf -- "$MOUNT_DIR"' EXIT # 确保临时挂载目录在脚本退出时被清理
mount -o loop "$ROOTFS_NAME" "$MOUNT_DIR"
echo "Copying rootfs contents to image..."
rsync -aHAXx --info=progress2 "$ROOTFS_DIR/" "$MOUNT_DIR/"
echo "Unmounting image..."
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR" # 移除空目录
echo "Rootfs image created as $ROOTFS_NAME"

# 7. 最小化并压缩 img 文件
echo "Minimizing the image file..."
e2fsck -f -y "$ROOTFS_NAME"
resize2fs -M "$ROOTFS_NAME"
BLOCK_SIZE=$(tune2fs -l "$ROOTFS_NAME" | grep 'Block size' | awk '{print $3}')
BLOCK_COUNT=$(dumpe2fs -h "$ROOTFS_NAME" | grep 'Block count' | awk '{print $3}')
NEW_SIZE=$((BLOCK_SIZE * BLOCK_COUNT))
truncate -s $NEW_SIZE "$ROOTFS_NAME"
echo "Image minimized to $NEW_SIZE bytes (new size: $NEW_SIZE)."