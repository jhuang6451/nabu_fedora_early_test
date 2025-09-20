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
    # 确保目标目录存在
    mkdir -p "$ROOTFS_DIR/proc" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/dev" "$ROOTFS_DIR/dev/pts"
    mount --bind /proc "$ROOTFS_DIR/proc"
    mount --bind /sys "$ROOTFS_DIR/sys"
    mount --bind /dev "$ROOTFS_DIR/dev"
    mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"
    mount --bind /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
}

# Unmount chroot filesystems 函数
umount_chroot_fs() {
    echo "Unmounting chroot filesystems from $ROOTFS_DIR..."
    # 以相反的顺序卸载，并忽略可能发生的错误
    umount "$ROOTFS_DIR/dev/pts" || true
    umount "$ROOTFS_DIR/dev" || true
    umount "$ROOTFS_DIR/sys" || true
    umount "$ROOTFS_DIR/proc" || true
    umount "$ROOTFS_DIR/etc/resolv.conf" || true
}

# 确保在脚本退出时总是尝试卸载
trap umount_chroot_fs EXIT

# 1. 创建 rootfs 目录
echo "Creating rootfs directory: $ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 2. 引导基础系统 (Bootstrap Phase)
# 安装一个包含 bash 和 dnf 的最小化系统，以便我们可以 chroot 进去
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

echo "Bootstrapping base system into rootfs..."
dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" \
    --releasever="$RELEASEVER" \
    --setopt=install_weak_deps=False \
    --setopt="reposdir=${TEMP_REPO_DIR}" \
    --nogpgcheck \
    fedora-repos \
    @core

# 3. 在 Chroot 环境中安装和配置
echo "Mounting filesystems for chroot..."
mount_chroot_fs

echo "Running main installation and configuration inside chroot..."
# 现在 $ROOTFS_DIR 里面有 /bin/bash 了，可以安全地 chroot
chroot "$ROOTFS_DIR" /bin/bash -c "
    set -e
    RELEASEVER=\"$RELEASEVER\"
    ARCH=\"$ARCH\"

    echo 'Installing additional packages...'
    dnf install -y --releasever=\$RELEASEVER \
        --repofrompath=\"jhuang6451-copr,https://download.copr.fedorainfracloud.org/results/jhuang6451/nabu_fedora_packages_uefi/fedora-\$RELEASEVER-\$ARCH/\" \
        --repofrompath=\"onesaladleaf-copr,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-\$RELEASEVER-\$ARCH/\" \
        --nogpgcheck \
        --setopt=install_weak_deps=False --exclude dracut-config-rescue \
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

    echo 'Creating qbootctl.service file...'
    cat <<EOF > \"/etc/systemd/system/qbootctl.service\"
[Unit]
Description=Qualcomm boot slot ctrl mark boot successful
[Service]
ExecStart=/usr/bin/qbootctl -m
Type=oneshot
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

    echo 'Enabling systemd services...'
    systemctl enable tqftpserv.service
    systemctl enable rmtfs.service
    systemctl enable qbootctl.service

    echo 'Cleaning dnf cache...'
    dnf clean all
"

echo "Chroot operations completed. Unmounting filesystems..."
umount_chroot_fs
# 重置 trap，因为我们已经手动卸载了
trap - EXIT

# 4. 将 rootfs 打包为 img 文件 (注意：这里不再需要 dnf clean all)
echo "Creating rootfs image: $ROOTFS_NAME (size: $IMG_SIZE)..."
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
mkfs.ext4 -F "$ROOTFS_NAME"
MOUNT_DIR=$(mktemp -d)
trap 'rmdir -- "$MOUNT_DIR"' EXIT # 确保临时挂载目录在脚本退出时被清理
mount -o loop "$ROOTFS_NAME" "$MOUNT_DIR"
echo "Copying rootfs contents to image..."
rsync -aHAXx --info=progress2 "$ROOTFS_DIR/" "$MOUNT_DIR/"
echo "Unmounting image..."
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
trap - EXIT # 再次重置 trap
echo "Rootfs image created as $ROOTFS_NAME"

# 5. 最小化并压缩 img 文件
echo "Minimizing the image file..."
e2fsck -f -y "$ROOTFS_NAME"
resize2fs -M "$ROOTFS_NAME"
BLOCK_SIZE=\$(tune2fs -l "$ROOTFS_NAME" | grep 'Block size' | awk '{print \$3}')
BLOCK_COUNT=\$(dumpe2fs -h "$ROOTFS_NAME" | grep 'Block count' | awk '{print \$3}')
NEW_SIZE=\$((BLOCK_SIZE * BLOCK_COUNT))
truncate -s \$NEW_SIZE "$ROOTFS_NAME"
echo "Image minimized to \$NEW_SIZE bytes."