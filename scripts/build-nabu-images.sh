#!/bin/bash

############################################################################################################################################
## Name: build-nabu-images-v3.3.sh                                                                                                          ##
## Author: jhuang6451 <xplayerhtz123@outlook.com>                                                                                         ##
## Time: 2025-9-12                                                                                                                        ##
## Description:                                                                                                                           ##
##  ZH-CN:                                                                                                                                ##
##      脚本用于构建适用于小米平板5(设备代号: nabu)的Fedora Workstation系统安装镜像                                                       ##
##      注意⚠️：如果需要调整或更新kernel版本，请修改脚本中对应的kernel包名称                                                              ##
##      nabu专用包构建于：https://copr.fedorainfracloud.org/coprs/jhuang6451/nabu_fedora_packages_uefi/                                   ##
##  EN:                                                                                                                                   ##
##      This script builds a Fedora Workstation system image tailored for Xiaomi Pad 5 (codename: nabu).                                  ##
##      Note⚠️: If you need to adjust or update the kernel version, please modify the corresponding kernel package name in the script.    ##
##      The nabu-specific packages are built at: https://copr.fedorainfracloud.org/coprs/jhuang6451/nabu_fedora_packages_uefi/            ##
############################################################################################################################################

set -e # 如果任何命令失败，则立即退出脚本

# --- 脚本配置 ---
TIMESTAMP=$(date +%Y%m%d)
COPR_REPOS=(
    "jhuang6451/nabu_fedora_packages_uefi"
    "onesaladleaf/pocketblue"
    "onesaladleaf/mobility-common"
)
FEDORA_RELEASE="42"
ROOTFS_IMG="fedora-nabu-rootfs-${TIMESTAMP}.img"
ESP_IMG="nabu-esp-${TIMESTAMP}.img"
ROOTFS_INITIAL_SIZE="10G"
ESP_SIZE="512M"
REFIND_SOURCE_DIR="${REFIND_SOURCE_DIR:-./refind_src}"

# --- 依赖检查 ---
echo "INFO: 正在检查所需工具..."
for cmd in sudo dnf truncate mkfs.ext4 mkfs.vfat guestmount guestunmount rpm2cpio cpio mcopy blkid tune2fs e2fsck resize2fs; do
    if ! command -v $cmd &> /dev/null; then
        echo "错误: 命令 '$cmd' 未找到。请安装必要的软件包。"
        exit 1
    fi
done
echo "INFO: 所有工具均已就绪。"


# --- 阶段 1: 构建 Fedora Rootfs ---
echo "##############################################"
echo "### 阶段 1: 开始构建 Rootfs ($ROOTFS_IMG)"
echo "##############################################"

echo "INFO: 正在创建 ${ROOTFS_INITIAL_SIZE} 大小的镜像文件: ${ROOTFS_IMG}"
truncate -s $ROOTFS_INITIAL_SIZE $ROOTFS_IMG
mkfs.ext4 -L "fedora_root" $ROOTFS_IMG

INSTALL_ROOT=$(mktemp -d)
trap 'sudo umount "$INSTALL_ROOT" 2>/dev/null; rmdir "$INSTALL_ROOT"' EXIT

echo "INFO: 正在挂载Rootfs镜像到临时目录: $INSTALL_ROOT"
sudo mount -o loop $ROOTFS_IMG $INSTALL_ROOT

# --- 配置仓库并安装基本软件包 ---
echo "INFO: 步骤 1/3 - 正在为 aarch64 安装官方 Fedora 仓库 (禁用GPG检查)..."
sudo dnf --installroot=$INSTALL_ROOT --releasever=$FEDORA_RELEASE --forcearch=aarch64 -y --use-host-config --nogpgcheck install fedora-repos

echo "INFO: 步骤 2/3 - 正在为 aarch64 手动创建所有 COPR 仓库文件..."
sudo mkdir -p "$INSTALL_ROOT/etc/yum.repos.d/"
for repo in "${COPR_REPOS[@]}"; do
    COPR_OWNER=$(echo $repo | cut -d'/' -f1)
    COPR_PROJECT=$(echo $repo | cut -d'/' -f2)
    echo "  -> Adding ${repo}"
    sudo bash -c "cat > '$INSTALL_ROOT/etc/yum.repos.d/_copr_${COPR_OWNER}_${COPR_PROJECT}.repo'" << EOF
[copr:copr.fedorainfracloud.org:${COPR_OWNER}:${COPR_PROJECT}]
name=Copr repo for ${COPR_PROJECT} owned by ${COPR_OWNER}
baseurl=https://download.copr.fedorainfracloud.org/results/${repo}/fedora-${FEDORA_RELEASE}-aarch64/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/${repo}/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
EOF
done

echo "INFO: 步骤 3/3 - 正在安装基础系统和工具..."
sudo dnf --installroot=$INSTALL_ROOT \
         --releasever=$FEDORA_RELEASE \
         --forcearch=aarch64 \
         --exclude dracut-config-rescue \
         -y install \
    # 基础GNOME桌面环境
    @gnome-desktop \
    # 核心桌面应用
    gnome-terminal \
    nautilus \
    gnome-software \
    firefox \
    # 系统必备组件
    xiaomi-nabu-firmware \
    xiaomi-nabu-audio \
    grub2-efi-aa64 \
    grub2-efi-aa64-modules \
    systemd-oomd-defaults \
    systemd-resolved \
    glibc-langpack-en \
    fuse \
    # 高通平台组件
    qbootctl \
    tqftpserv \
    pd-mapper \
    rmtfs \
    qrtr \
    # 实用工具
    NetworkManager-tui \
    git \
    grubby \
    vim

echo "INFO: 步骤 4/4 - 正在移除官方内核并安装定制内核..."
# 移除可能被默认安装的官方内核
sudo dnf --installroot=$INSTALL_ROOT -y remove kernel kernel-core kernel-modules kernel-modules-core --noautoremove
# 安装定制内核
sudo dnf --installroot=$INSTALL_ROOT -y install kernel-sm8150

# --- 启用关键服务 ---
echo "INFO: 正在注入并启用 qbootctl 成功启动标记服务..."
sudo bash -c "cat > '$INSTALL_ROOT/etc/systemd/system/qbootctl-mark-boot-successful.service'" << EOF
[Unit]
Description=Qualcomm boot slot ctrl mark boot successful

[Service]
ExecStart=/usr/bin/qbootctl -m
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

echo "INFO: 正在启用关键服务..."
sudo systemd-nspawn -D "$INSTALL_ROOT" systemctl enable tqftpserv.service rmtfs.service gdm.service

# --- 注入首次启动时文件系统扩展服务 ---
echo "INFO: 正在注入首次启动自动扩展文件系统的服务..."
# 1. 创建服务文件
sudo mkdir -p "$INSTALL_ROOT/etc/systemd/system/"
sudo bash -c "cat > '$INSTALL_ROOT/etc/systemd/system/resize-rootfs.service'" << EOF
[Unit]
Description=Resize root filesystem to fill partition
DefaultDependencies=no
After=systemd-remount-fs.service
Before=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/resize-rootfs.sh
StandardOutput=journal+console
StandardError=journal+console
RemainAfterExit=no

[Install]
WantedBy=basic.target
EOF

# 2. 创建执行脚本
sudo mkdir -p "$INSTALL_ROOT/usr/local/bin/"
sudo bash -c "cat > '$INSTALL_ROOT/usr/local/bin/resize-rootfs.sh'" << 'EOF'
#!/bin/bash
set -e
ROOT_PART=$(findmnt -n -o SOURCE /)
echo "INFO: Resizing ${ROOT_PART} to fill the partition..."
resize2fs ${ROOT_PART}
echo "INFO: Filesystem resized. Disabling service for next boot."
rm -f /etc/systemd/system/resize-rootfs.service
rm -f /usr/local/bin/resize-rootfs.sh
EOF

# 3. 设置权限并启用服务
sudo chmod 755 "$INSTALL_ROOT/usr/local/bin/resize-rootfs.sh"
sudo systemd-nspawn -D "$INSTALL_ROOT" systemctl enable resize-rootfs.service
# ----------------------------------------------------

echo 'root:fedora' | sudo chpasswd --root $INSTALL_ROOT
echo "警告: 已设置默认root密码为 'fedora'。首次登录后请立即修改！"

# --- 卸载前清理操作 ---
echo "INFO: 正在清理日志和DNF缓存以减小镜像体积..."
sudo rm -rf "$INSTALL_ROOT/var/log/*"
sudo dnf --installroot=$INSTALL_ROOT clean all

# --- 卸载 Rootfs 镜像 ---
echo "INFO: 卸载 Rootfs 镜像..."
sudo umount $INSTALL_ROOT
rmdir $INSTALL_ROOT
trap - EXIT

# --- 收缩Rootfs镜像到最小尺寸 ---
echo "INFO: 正在将Rootfs镜像收缩到最小尺寸..."
sudo e2fsck -f -y $ROOTFS_IMG
sudo resize2fs -M $ROOTFS_IMG
BLOCKS=$(sudo tune2fs -l $ROOTFS_IMG | grep 'Block count' | awk '{print $3}')
BLOCK_SIZE=$(sudo tune2fs -l $ROOTFS_IMG | grep 'Block size' | awk '{print $3}')
NEW_SIZE=$((BLOCKS * BLOCK_SIZE))
echo "INFO: Rootfs最小尺寸计算为 ${NEW_SIZE} 字节。"
truncate -s $NEW_SIZE $ROOTFS_IMG
echo "INFO: Rootfs镜像已成功收缩。"
# ------------------------------------

echo "INFO: Rootfs 构建完成: ${ROOTFS_IMG}"


# --- 阶段 2: 构建 ESP (EFI System Partition) ---
echo "##############################################"
echo "### 阶段 2: 开始构建 ESP ($ESP_IMG)"
echo "##############################################"
ESP_WORKDIR=$(mktemp -d)
trap 'rm -rf "$ESP_WORKDIR"' EXIT
echo "INFO: 创建ESP工作目录: $ESP_WORKDIR"
mkdir -p $ESP_WORKDIR/EFI/{BOOT,fedora}
mkdir -p $ESP_WORKDIR/fedora

echo "INFO: 正在下载并提取 GRUB aarch64 EFI..."
dnf download --quiet --arch=aarch64 grub2-efi-aa64
rpm2cpio grub2-efi-aa64-*.rpm | cpio -idmv &>/dev/null
GRUB_EFI_PATH="./boot/efi/EFI/fedora/grubaa64.efi"

echo "INFO: 正在从 ${ROOTFS_IMG} 中提取内核和DTB..."
MOUNT_DIR=$(mktemp -d)
trap 'sudo umount "$MOUNT_DIR" 2>/dev/null; rmdir "$MOUNT_DIR"; rm -rf "$ESP_WORKDIR" boot grub2-efi-aa64-*.rpm' EXIT
sudo guestmount -a $ROOTFS_IMG -r -m /dev/sda $MOUNT_DIR
KERNEL_VERSION=$(basename $(ls $MOUNT_DIR/boot/vmlinuz-*))
KERNEL_VERSION=${KERNEL_VERSION#vmlinuz-}
cp "$MOUNT_DIR/boot/vmlinuz-${KERNEL_VERSION}" "$ESP_WORKDIR/fedora/Image"
cp "$MOUNT_DIR/usr/lib/modules/${KERNEL_VERSION}/dtb/qcom/sm8150-xiaomi-nabu.dtb" "$ESP_WORKDIR/fedora/sm8150-xiaomi-nabu.dtb"
sudo guestunmount $MOUNT_DIR
rmdir $MOUNT_DIR

ROOTFS_UUID=$(sudo tune2fs -l $ROOTFS_IMG | grep 'Filesystem UUID' | awk '{print $3}')
truncate -s $ESP_SIZE $ESP_IMG
mkfs.vfat -n "ESP" $ESP_IMG > /dev/null
ESP_UUID=$(sudo blkid $ESP_IMG | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')

# 预生成GRUB配置内容
read -r -d '' GRUB_CFG_CONTENT <<EOF
# Generated by build-nabu-images.sh
set timeout=5
set default="0"
menuentry "Fedora Workstation (nabu)" {
    search --fs-uuid --set=root $ESP_UUID
    linux /fedora/Image root=UUID=$ROOTFS_UUID rw quiet splash
    devicetree /fedora/sm8150-xiaomi-nabu.dtb
}
EOF

# --- 自动检测rEFInd并选择启动方案 ---
if [ -f "${REFIND_SOURCE_DIR}/refind_aa64.efi" ]; then
    echo "INFO: 检测到 '${REFIND_SOURCE_DIR}' 目录，将安装 rEFInd 作为主引导器。"
    # 方案A: rEFInd + GRUB
    cp "${REFIND_SOURCE_DIR}/refind_aa64.efi" "$ESP_WORKDIR/EFI/BOOT/BOOTAA64.EFI"
    cp "${REFIND_SOURCE_DIR}/refind.conf-sample" "$ESP_WORKDIR/EFI/BOOT/refind.conf"
    [ -d "${REFIND_SOURCE_DIR}/icons" ] && cp -r "${REFIND_SOURCE_DIR}/icons" "$ESP_WORKDIR/EFI/BOOT/"
    [ -d "${REFIND_SOURCE_DIR}/drivers_aa64" ] && cp -r "${REFIND_SOURCE_DIR}/drivers_aa64" "$ESP_WORKDIR/EFI/BOOT/"
    cp "$GRUB_EFI_PATH" "$ESP_WORKDIR/EFI/fedora/grubaa64.efi"
    
    echo "$GRUB_CFG_CONTENT" > "$ESP_WORKDIR/EFI/fedora/grub.cfg"
    
    cat << EOF >> "$ESP_WORKDIR/EFI/BOOT/refind.conf"
menuentry "Fedora Workstation" {
    loader /EFI/fedora/grubaa64.efi
    icon /EFI/BOOT/icons/os_fedora.png
}
EOF
else
    echo "INFO: 未检测到 '${REFIND_SOURCE_DIR}/refind_aa64.efi'，将安装 GRUB 作为主引导器。"
    # 方案B: 仅 GRUB
    cp "$GRUB_EFI_PATH" "$ESP_WORKDIR/EFI/BOOT/BOOTAA64.EFI"
    echo "$GRUB_CFG_CONTENT" > "$ESP_WORKDIR/EFI/BOOT/grub.cfg"
fi
# ---------------------------------------------

echo "INFO: 正在将所有文件写入ESP镜像: ${ESP_IMG}"
mcopy -s -i $ESP_IMG $ESP_WORKDIR/* ::

# 清理
rm -rf $ESP_WORKDIR boot grub2-efi-aa64-*.rpm
trap - EXIT


echo "##############################################"
echo "### 构建成功！"
echo "##############################################"
echo "生成的镜像文件:"
echo "- Rootfs: ${ROOTFS_IMG} "
echo "- ESP:    ${ESP_IMG}"
