#!/bin/bash

# ----- THIS VERSION IS FOR TESTING ONLY -----

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
}

# Unmount chroot filesystems 函数
umount_chroot_fs() {
    echo "Unmounting chroot filesystems from $ROOTFS_DIR..."
    # 以相反的顺序卸载，并忽略可能发生的错误
    umount "$ROOTFS_DIR/dev/pts" || true
    umount "$ROOTFS_DIR/dev" || true
    umount "$ROOTFS_DIR/sys" || true
    umount "$ROOTFS_DIR/proc" || true
}

# 确保在脚本退出时总是尝试卸载
trap umount_chroot_fs EXIT

# 1. 创建 rootfs 目录
echo "Creating rootfs directory: $ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 2. 先挂载必要的文件系统，以便后续 chroot 操作
echo "Mounting filesystems for chroot..."
mount_chroot_fs

# 创建临时 DNS 配置 
echo "Temporarily setting up DNS for chroot..."
# 强制删除任何可能存在的旧文件或悬空链接
rm -f "$ROOTFS_DIR/etc/resolv.conf"
# 创建一个新的 resolv.conf 文件
mkdir -p "$ROOTFS_DIR/etc"
cat <<EOF > "$ROOTFS_DIR/etc/resolv.conf"
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

# 3. 引导基础系统 (Bootstrap Phase)
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

# 4. 在 Chroot 环境中安装和配置
echo "Running main installation and configuration inside chroot..."
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
        kernel-sm8150 \
        xiaomi-nabu-firmware \
        systemd-boot-unsigned \
        binutils

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


    echo 'Creating /etc/fstab for automatic partition mounting...'
    cat <<EOF > "/etc/fstab"
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a device; this may
# be used with UUID= as a more robust way to name devices that works even if
# disks are added and removed. See fstab(5).
#
# <file system>  <mount point>  <type>  <options>  <dump>  <pass>
LABEL=fedora_root  /              ext4    defaults,x-systemd.device-timeout=0   1 1
LABEL=ESP          /boot/efi      vfat    umask=0077,shortname=winnt            0 2
EOF


    echo 'Detecting installed kernel version for dracut config...'
    KERNEL_VERSION=\$(ls /lib/modules | sort -rV | head -n1)
    if [ -z \"\$KERNEL_VERSION\" ]; then
        echo 'ERROR: No kernel version found inside chroot!' >&2
        exit 1
    fi
    echo \"Detected kernel version: \$KERNEL_VERSION\"

    echo 'Creating dracut config for automated UKI generation...'
    mkdir -p \"/etc/dracut.conf.d/\"
    cat <<EOF > \"/etc/dracut.conf.d/99-nabu-uki.conf\"
uefi=yes
uefi_stub=/usr/lib/systemd/boot/efi/linuxaarch64.efi.stub
# 使用动态检测到的内核版本路径
devicetree=\"/usr/lib/modules/\$KERNEL_VERSION/dtb/qcom/sm8150-xiaomi-nabu.dtb\"
uefi_cmdline=\"root=LABEL=fedora_root rw quiet\"
EOF

    echo 'Dracut config created.'

    # 安装内核时，dracut会自动运行并根据新配置生成UKI
    # 生成的UKI会默认放在 /boot/efi/EFI/Linux/fedora-<hash>.efi
    # 我们可以强制它重新生成一次，确保初始镜像是最新的
    echo 'Re-running dracut to generate the initial UKI...'
    dracut --force --kver \"\$KERNEL_VERSION\"

    echo 'Cleaning dnf cache...'
    dnf clean all
"

# 5. 退出 chroot 并卸载文件系统
echo "Chroot operations completed. Unmounting filesystems..."
umount_chroot_fs
# 重置 trap，因为我们已经手动卸载了
trap - EXIT

# 6. 将 rootfs 打包为 img 文件 (注意：这里不再需要 dnf clean all)
echo "Creating rootfs image: $ROOTFS_NAME (size: $IMG_SIZE)..."
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
mkfs.ext4 -L fedora_root -F "$ROOTFS_NAME" # 设置标签
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
e2fsck -f -y "$ROOTFS_NAME" || true # 忽略可能出现的“clean”错误
echo "Resizing filesystem to minimum size..."
resize2fs -M "$ROOTFS_NAME"

# 更稳健地获取块大小和块数量
echo "Calculating new image size..."
BLOCK_INFO=$(dumpe2fs -h "$ROOTFS_NAME" 2>/dev/null)
BLOCK_SIZE=$(echo "$BLOCK_INFO" | grep 'Block size:' | awk '{print $3}')
BLOCK_COUNT=$(echo "$BLOCK_INFO" | grep 'Block count:' | awk '{print $3}')

# 检查是否成功获取了数值
if ! [[ "$BLOCK_SIZE" =~ ^[0-9]+$ ]] || ! [[ "$BLOCK_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Error: Failed to retrieve block size or block count from image."
    exit 1
fi

# 计算新的大小并进行 truncate
NEW_SIZE=$((BLOCK_SIZE * BLOCK_COUNT))
echo "New calculated size is $NEW_SIZE bytes."
truncate -s $NEW_SIZE "$ROOTFS_NAME"
echo "Image minimized successfully."