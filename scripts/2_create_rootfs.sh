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

# ==============================================================================
# 2. 使用 Metalink 引导基础仓库
#
# 创建一个临时的 repo 配置文件，该文件使用 metalink 来动态查找最佳镜像。
# 这是最稳健的方法，可以避免硬编码 baseurl 导致的下载失败。
# ==============================================================================
echo "Bootstrapping Fedora repositories for $ARCH using metalink..."

# 创建一个临时目录来存放 repo 文件
TEMP_REPO_DIR=$(mktemp -d)
# 设置一个 trap，确保脚本退出时（无论成功还是失败）都会删除临时目录
trap 'rm -rf -- "$TEMP_REPO_DIR"' EXIT

# 在临时目录中创建 repo 文件
cat <<EOF > "${TEMP_REPO_DIR}/temp-fedora.repo"
[temp-fedora]
name=Temporary Fedora $RELEASEVER - $ARCH
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-$RELEASEVER&arch=$ARCH
enabled=1
gpgcheck=0
skip_if_unavailable=False
EOF

# 使用 --setopt=reposdir 指向我们的临时目录，安装基础仓库配置文件
# 这会强制 dnf 仅使用我们提供的这个 repo 文件，避免与宿主机仓库冲突
dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" \
    --setopt="reposdir=${TEMP_REPO_DIR}" \
    --releasever="$RELEASEVER" \
    fedora-repos


# ==============================================================================
# 3. 安装所有软件包
#
# 现在 rootfs 中已经有了官方的仓库配置，我们可以继续安装所有需要的软件包。
# 我们只需要通过 --repofrompath 额外添加 COPR 仓库即可。
# ==============================================================================
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


# # ==============================================================================
# # 2. 引导基础仓库
# # 先安装 fedora-repos 包，为 rootfs 提供官方的仓库配置文件。
# # ==============================================================================
# echo "Bootstrapping Fedora repositories for $ARCH..."
# dnf install -y --installroot="$ROOTFS_DIR" --forcearch="$ARCH" \
#     --repofrompath="fedora-repo,https://dl.fedoraproject.org/pub/fedora/linux/releases/$RELEASEVER/Everything/$ARCH/os/" \
#     --releasever="$RELEASEVER" \
#     --nogpgcheck \
#     fedora-repos

# # ==============================================================================
# # 3. 启用所需的 COPR 仓库
# # 在官方仓库配置就绪后，再启用 COPR 仓库。
# # ==============================================================================
# echo "Enabling COPR repositories..."
# dnf copr enable -y --installroot="$ROOTFS_DIR" jhuang6451/nabu_fedora_packages_uefi fedora-42-aarch64
# dnf copr enable -y --installroot="$ROOTFS_DIR" onesaladleaf/pocketblue fedora-42-aarch64

# # ==============================================================================
# # 4. 安装所有软件包
# # 现在，dnf 可以同时看到官方仓库和 COPR 仓库。
# # ==============================================================================
# dnf install -y --installroot="$ROOTFS_DIR" --releasever="$RELEASEVER" --forcearch="$ARCH" \
#     --setopt=install_weak_deps=False \
#     --exclude dracut-config-rescue \
#     --enablerepo="copr:copr.fedorainfracloud.org:jhuang6451:nabu_fedora_packages_uefi" \
#     --enablerepo="copr:copr.fedorainfracloud.org:onesaladleaf:pocketblue" \
#     @core \
#     @hardware-support \
#     @standard \
#     @base-graphical \
#     NetworkManager-tui \
#     git \
#     grubby \
#     vim \
#     glibc-langpack-en \
#     btrfs-progs \
#     systemd-resolved \
#     grub2-efi-aa64 \
#     grub2-efi-aa64-modules \
#     qbootctl \
#     tqftpserv \
#     pd-mapper \
#     rmtfs \
#     qrtr \
#     kernel-sm8150 \
#     xiaomi-nabu-firmware \
#     xiaomi-nabu-audio

# 5. Chroot 并配置系统
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

# 6. 清理 rootfs 以减小体积
# 清除dnf缓存
dnf clean all --installroot="$ROOTFS_DIR"
# 移除 qemu-static
rm "${ROOTFS_DIR}/usr/bin/qemu-aarch64-static"

# 7. 将 rootfs 打包为 img 文件
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

# 8. 最小化并压缩 img 文件
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