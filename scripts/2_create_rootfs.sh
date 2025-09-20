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

echo "Cleaning up temporary repository..."
rm -rf -- "$TEMP_REPO_DIR"

# 4. 在 Chroot 环境中安装和配置
echo "Running main installation and configuration inside chroot..."

run_in_chroot() {
    # 将变量导出，以便子 shell (chroot) 可以继承它们
    export RELEASEVER="$RELEASEVER"
    export ARCH="$ARCH"

    # 使用 cat 将此函数内的所有命令通过管道传给 chroot
    cat <<'CHROOT_SCRIPT' | chroot "$ROOTFS_DIR" /bin/bash
set -e
set -o pipefail

echo 'Installing additional packages...'
dnf install -y --releasever=$RELEASEVER \
    --repofrompath="jhuang6451-copr,https://download.copr.fedorainfracloud.org/results/jhuang6451/nabu_fedora_packages_uefi/fedora-$RELEASEVER-$ARCH/" \
    --repofrompath="onesaladleaf-copr,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-$RELEASEVER-$ARCH/" \
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
    xiaomi-nabu-audio \
    systemd-boot-unsigned \
    binutils \
    zram-generator



echo 'Creating qbootctl.service file...'
cat <<EOF > "/etc/systemd/system/qbootctl.service"
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



echo 'Creating /etc/fstab for automatic partition mounting...'
cat <<EOF > "/etc/fstab"
# /etc/fstab: static file system information.
LABEL=fedora_root  /              ext4    defaults,x-systemd.device-timeout=0   1 1
LABEL=ESP          /boot/efi      vfat    umask=0077,shortname=winnt            0 2
EOF



echo 'Creating DYNAMIC dracut config for automated UKI generation...'
mkdir -p "/etc/dracut.conf.d/"
cat <<EOF > "/etc/dracut.conf.d/99-nabu-uki.conf"
# This is a dynamically-aware configuration for dracut.
uefi=yes
uefi_stub=/usr/lib/systemd/boot/efi/linuxaarch64.efi.stub
# 使用 dracut 内部的 '\${kernel}' 变量
devicetree="/usr/lib/modules/\${kernel}/dtb/qcom/sm8150-xiaomi-nabu.dtb"
uefi_cmdline="root=LABEL=fedora_root rw quiet"
EOF
echo 'Dracut config created.'



echo 'Detecting installed kernel version for initial UKI generation...'
KERNEL_VERSION=$(ls /lib/modules | sort -rV | head -n1)
if [ -z "$KERNEL_VERSION" ]; then
    echo 'ERROR: No kernel version found inside chroot!' >&2
    exit 1
fi
echo "Detected kernel version for kernel-install: $KERNEL_VERSION"



echo 'Configuring kernel-install to generate UKIs...'
mkdir -p "/etc/kernel/"
cat <<EOF > "/etc/kernel/install.conf"
# Tell kernel-install to use dracut as the UKI generator.
uki_generator=dracut
EOF



echo 'Running kernel-install to generate the initial UKI...'
kernel-install add "$KERNEL_VERSION" "/boot/vmlinuz-$KERNEL_VERSION"



echo 'Creating systemd-boot loader configuration...'
mkdir -p "/boot/efi/loader/"
cat <<EOF > "/boot/efi/loader/loader.conf"
# See loader.conf(5) for details
timeout 3
console-mode max
default fedora-*
EOF



echo 'Creating first-boot resize service...'

cat <<'EOF' > "/usr/local/bin/firstboot-resize.sh"
#!/bin/bash
set -e
# 获取根分区的设备路径 (e.g., /dev/mmcblk0pXX)
ROOT_DEV=$(findmnt -n -o SOURCE /)
if [ -z "$ROOT_DEV" ]; then
    echo "Could not find root device. Aborting resize." >&2
    exit 1
fi
echo "Resizing filesystem on ${ROOT_DEV}..."
# 扩展文件系统以填充整个分区
resize2fs "${ROOT_DEV}"
# 任务完成，禁用并移除此服务，确保下次启动不再运行
systemctl disable firstboot-resize.service
rm -f /etc/systemd/system/firstboot-resize.service
rm -f /usr/local/bin/firstboot-resize.sh
echo "Filesystem resized and service removed."
EOF

# 赋予脚本执行权限
chmod +x "/usr/local/bin/firstboot-resize.sh"

# 创建 systemd 服务单元
cat <<EOF > "/etc/systemd/system/firstboot-resize.service"
[Unit]
Description=Resize root filesystem to fill partition on first boot
# 确保在文件系统挂载后执行
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/firstboot-resize.sh
# StandardOutput=journal+console
RemainAfterExit=false

[Install]
# 链接到默认的目标，使其能够自启动
WantedBy=default.target
EOF

# 启用服务
systemctl enable firstboot-resize.service
echo 'First-boot resize service created and enabled.'



echo 'Adding udev rule for asynchronous firmware loading to improve boot times...'
mkdir -p "/etc/udev/rules.d/"
cat <<EOF > "/etc/udev/rules.d/99-async-firmware-load.rules"
# This rule tells the kernel to load firmware files in the background
# ("asynchronously") instead of pausing the boot process to wait for them.
# This dramatically speeds up boot times, especially if a driver requests
# firmware that doesn't exist.
SUBSYSTEM=="firmware", ACTION=="add", ATTR{loading}="-1"
EOF
echo 'Asynchronous firmware loading rule created.'



echo 'Configuring zram swap for improved performance under memory pressure...'
# zram-generator-defaults is installed but we want to provide our own config
mkdir -p "/etc/systemd/"
cat <<EOF > "/etc/systemd/zram-generator.conf"
# This configuration enables a compressed RAM-based swap device (zram).
# It significantly improves system responsiveness and multitasking on
# devices with a fixed amount of RAM.
[zram0]
# Set the uncompressed swap size to be equal to the total physical RAM.
# This is a balanced value providing a large swap space without risking
# system thrashing under heavy load.
zram-size = ram

# Use zstd compression for the best balance of speed and compression ratio.
compression-algorithm = zstd
EOF
echo 'Zram swap configured.'



echo 'Adding creator signature to /etc/os-release...'
echo 'BUILD_CREATOR="jhuang6451"' >> "/etc/os-release"



echo 'Cleaning dnf cache...'
dnf clean all

CHROOT_SCRIPT
}

# 现在执行这个函数
echo "Running main installation and configuration inside chroot..."
run_in_chroot



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