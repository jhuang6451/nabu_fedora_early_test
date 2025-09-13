#!/bin/bash

set -e

# 定义变量
ROOTFS_DIR="$PWD/fedora-rootfs-aarch64"
RELEASEVER="42"
ARCH="aarch64"
ROOTFS_NAME="fedora-42-nabu-rootfs.img" # 输出文件名
IMG_SIZE="8G" # 定义初始镜像大小，应确保足够容纳所有文件

# 确保宿主机已安装 qemu-user-static
if [ ! -f /usr/bin/qemu-aarch64-static ]; then
    echo "错误：/usr/bin/qemu-aarch64-static 未找到。"
    echo "请先安装 qemu-user-static 软件包 (例如：sudo dnf install qemu-user-static)。"
    exit 1
fi

# 1. 创建 rootfs 目录
mkdir -p "$ROOTFS_DIR"

# 1.5. 提前复制 QEMU 静态二进制文件
echo "Copying QEMU static binary for cross-architecture execution..."
# 确保目标目录存在
mkdir -p "${ROOTFS_DIR}/usr/bin/"
cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"

# 2. 使用 Metalink 引导基础仓库
echo "Bootstrapping Fedora repositories for $ARCH using metalink..."
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

# ==============================================================================
# 3. 阶段一：安装所有软件包，但不运行脚本
#
# 使用 --setopt=tsflags=noscripts 来解包所有文件，但跳过所有配置脚本。
# 这可以避免在不完整的环境中执行脚本而导致的失败。
# ==============================================================================
echo "Stage 1: Installing all packages without running scripts..."
PACKAGES=(
    "@core"
    "@hardware-support"
    "@standard"
    "@base-graphical"
    "NetworkManager-tui"
    "git"
    "grubby"
    "vim"
    "glibc-langpack-en"
    "btrfs-progs"
    "systemd-resolved"
    "grub2-efi-aa64"
    "grub2-efi-aa64-modules"
    "qbootctl"
    "tqftpserv"
    "pd-mapper"
    "rmtfs"
    "qrtr"
    "kernel-sm8150"
    "xiaomi-nabu-firmware"
    "xiaomi-nabu-audio"
)
dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" --releasever="$RELEASEVER" \
    --repofrompath="jhuang6451-copr,https://download.copr.fedorainfracloud.org/results/jhuang6451/nabu_fedora_packages_uefi/fedora-$RELEASEVER-$ARCH/" \
    --repofrompath="onesaladleaf-copr,https://download.copr.fedorainfracloud.org/results/onesaladleaf/pocketblue/fedora-$RELEASEVER-$ARCH/" \
    --nogpgcheck \
    --setopt=install_weak_deps=False --exclude dracut-config-rescue \
    --setopt=tsflags=noscripts \
    "${PACKAGES[@]}"

# ==============================================================================
# 4. 阶段二：Chroot 并完成配置
#
# 现在所有文件都已就位，我们 chroot 进入这个完整的环境，
# 然后通过 dnf reinstall 重新触发所有配置脚本的运行。
# ==============================================================================
echo "Stage 2: Chrooting into rootfs to run configuration scripts..."
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

# ==============================================================================
# Chroot 并执行 (关键修改)
# 我们显式调用 qemu-aarch64-static 来执行 chroot 环境中的 bash。
# 这绕过了在 CI 环境中可能不可靠的 binfmt_misc 自动触发机制。
# ==============================================================================
chroot "$ROOTFS_DIR" /usr/bin/qemu-aarch64-static /bin/bash -c "
    set -e
    echo 'Running dnf reinstall to execute package scripts...'
    # 重新安装所有软件包以运行它们的配置脚本
    dnf reinstall -y ${PACKAGES[*]}

    echo 'Enabling systemd services...'
    systemctl enable tqftpserv.service
    systemctl enable rmtfs.service
    systemctl enable qbootctl.service
"

# 5. 清理 rootfs 以减小体积
dnf clean all --installroot="$ROOTFS_DIR"
rm "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"

# ... (后续打包、压缩脚本部分保持不变) ...
# 6. 将 rootfs 打包为 img 文件
echo "Creating rootfs image..."
fallocate -l "$IMG_SIZE" "$ROOTFS_NAME"
mkfs.ext4 "$ROOTFS_NAME"
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