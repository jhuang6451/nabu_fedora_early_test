#!/bin/bash

############################################################################################################################################
## Name: build-nabu-images-v0.4.0.sh                                                                                                          ##
## Author: jhuang6451 <xplayerhtz123@outlook.com>                                                      ##
## Time: 2025-9-13                                                                                                                        ##
## Description:                                                                                                                           ##
##  ZH-CN:                                                                                                                                ##
##      脚本用于构建适用于小米平板5(设备代号: nabu)的Fedora Workstation系统安装镜像。                                                      ##                           ##
##  EN:                                                                                                                                   ##
##      This script builds a Fedora Workstation system image tailored for Xiaomi Pad 5 (codename: nabu).                                  ##      ##
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
for cmd in sudo dnf truncate mkfs.ext4 mkfs.vfat guestmount guestunmount rpm2cpio cpio mcopy blkid tune2fs e2fsck resize2fs rsync systemd-nspawn curl; do
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

# 创建临时的rootfs目录
INSTALL_ROOT=$(mktemp -d)
trap 'sudo rm -rf "$INSTALL_ROOT"' EXIT

echo "INFO: 创建临时Rootfs目录: $INSTALL_ROOT"

# --- 准备 chroot 环境 ---
echo "INFO: 步骤 1/4 - 准备 chroot 环境..."

# 1. 复制 QEMU 仿真器
echo "  -> 复制 QEMU aarch64 仿真器"
sudo mkdir -p "$INSTALL_ROOT/usr/bin"
sudo cp /usr/bin/qemu-aarch64-static "$INSTALL_ROOT/usr/bin/"

# 2. 复制 DNS 配置
echo "  -> 复制 DNS 配置"
sudo mkdir -p "$INSTALL_ROOT/etc"
sudo cp /etc/resolv.conf "$INSTALL_ROOT/etc/"

# 3. 在chroot环境中创建仓库配置文件
echo "  -> 创建仓库配置文件"
sudo mkdir -p "$INSTALL_ROOT/etc/yum.repos.d/"
echo "  -> 创建 Fedora 官方仓库文件"
sudo bash -c "cat > '$INSTALL_ROOT/etc/yum.repos.d/fedora.repo'" << EOF
[fedora]
name=Fedora \$releasever - \$basearch
baseurl=https://archives.fedoraproject.org/pub/fedora/linux/releases/\$releasever/Everything/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-primary
skip_if_unavailable=False
EOF
sudo bash -c "cat > '$INSTALL_ROOT/etc/yum.repos.d/fedora-updates.repo'" << EOF
[updates]
name=Fedora \$releasever - \$basearch - Updates
baseurl=https://archives.fedoraproject.org/pub/fedora/linux/updates/\$releasever/Everything/\$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-primary
skip_if_unavailable=False
EOF
echo "  -> 下载 GPG 密钥到 installroot"
sudo mkdir -p "$INSTALL_ROOT/etc/pki/rpm-gpg/"
sudo curl -o "$INSTALL_ROOT/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${FEDORA_RELEASE}-primary" \
     "https://src.fedoraproject.org/rpms/fedora-repos/raw/rawhide/f/RPM-GPG-KEY-fedora-${FEDORA_RELEASE}-primary"

# 创建 COPR 仓库文件
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

# --- 执行两步安装 ---
echo "INFO: 步骤 2/4 - 执行两步安装过程..."
packages=(
    "fedora-repos"
    "@gnome-desktop"
    "gnome-terminal" "nautilus" "gnome-software" "firefox"
    "xiaomi-nabu-firmware" "xiaomi-nabu-audio"
    "grub2-efi-aa64" "grub2-efi-aa64-modules"
    "systemd-oomd-defaults" "systemd-resolved"
    "glibc-langpack-en" "fuse"
    "qbootctl" "tqftpserv" "pd-mapper" "rmtfs" "qrtr"
    "NetworkManager-tui" "git" "grubby" "vim"
    "kernel-sm8150"
)

# 步骤 2a: 安装所有软件包，但不运行任何安装脚本
echo "  -> 步骤 2a: 安装软件包文件 (tsflags=noscripts)"
sudo dnf -y \
    --installroot="$INSTALL_ROOT" \
    --releasever=$FEDORA_RELEASE \
    --forcearch=aarch64 \
    --exclude dracut-config-rescue \
    --setopt=install_weak_deps=False \
    --setopt=tsflags=noscripts \
    install \
    "${packages[@]}"

# 步骤 2b: 进入 chroot 环境，重新安装软件包以触发安装脚本
echo "  -> 步骤 2b: 在 chroot 环境中重新安装以执行 %post 脚本"
# 注意: @gnome-desktop 组名在 reinstall 时可能无法直接使用，需要转换为其包含的包
# 为了简化，我们假定 reinstall 核心包足以触发大部分重要脚本
# 一个更稳健的方式是查询组内的包，但通常 reintall 关键包就够了
# 这里我们直接用 reinstall "${packages[@]}" 尝试，dnf 应该能处理好
sudo systemd-nspawn -D "$INSTALL_ROOT" /usr/bin/dnf -y reinstall "${packages[@]}"


# --- 在 chroot 环境中进行配置 ---
echo "INFO: 步骤 3/4 - 在 chroot 环境中配置系统..."

# 注入服务和脚本
echo "  -> 注入 qbootctl 服务"
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

echo "  -> 注入文件系统自动扩展服务"
sudo mkdir -p "$INSTALL_ROOT/etc/systemd/system/" "$INSTALL_ROOT/usr/local/bin/"
sudo bash -c "cat > '$INSTALL_ROOT/etc/systemd/system/resize-rootfs.service'" << EOF
[Unit]
Description=Resize root filesystem to fill partition
DefaultDependencies=no
After=systemd-remount-fs.service
Before=shutdown.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/resize-rootfs.sh
RemainAfterExit=no
[Install]
WantedBy=basic.target
EOF
sudo bash -c "cat > '$INSTALL_ROOT/usr/local/bin/resize-rootfs.sh'" << 'EOF'
#!/bin/bash
set -e
ROOT_PART=$(findmnt -n -o SOURCE /)
resize2fs ${ROOT_PART}
rm -f /etc/systemd/system/resize-rootfs.service
rm -f /usr/local/bin/resize-rootfs.sh
EOF
sudo chmod 755 "$INSTALL_ROOT/usr/local/bin/resize-rootfs.sh"

# 启用服务
echo "  -> 启用关键服务"
sudo systemd-nspawn -D "$INSTALL_ROOT" systemctl enable tqftpserv.service rmtfs.service gdm.service resize-rootfs.service qbootctl-mark-boot-successful.service

# 设置root密码
echo 'root:fedora' | sudo chpasswd --root $INSTALL_ROOT
echo "警告: 已设置默认root密码为 'fedora'。首次登录后请立即修改！"

# --- 清理 chroot 环境 ---
echo "INFO: 步骤 4/4 - 清理环境..."
echo "  -> 清理 DNF 缓存"
sudo systemd-nspawn -D "$INSTALL_ROOT" /usr/bin/dnf clean all
echo "  -> 移除临时文件"
sudo rm -rf "$INSTALL_ROOT/var/log/*"
sudo rm -f "$INSTALL_ROOT/usr/bin/qemu-aarch64-static"
sudo rm -f "$INSTALL_ROOT/etc/resolv.conf"

# --- 从构建好的目录创建最终的镜像文件 ---
echo "INFO: 开始从目录创建最终的 Rootfs 镜像文件..."

echo "  -> 计算所需空间并创建镜像文件"
ROOTFS_SIZE_BYTES=$(sudo du -sb "$INSTALL_ROOT" | awk '{print $1}')
# 增加 20% 的额外空间以确保能容纳元数据等
ROOTFS_FINAL_SIZE=$((ROOTFS_SIZE_BYTES * 12 / 10))
echo "  -> 内容大小: ${ROOTFS_SIZE_BYTES} B, 最终镜像大小: ${ROOTFS_FINAL_SIZE} B"
truncate -s $ROOTFS_FINAL_SIZE $ROOTFS_IMG
mkfs.ext4 -L "fedora_root" $ROOTFS_IMG

echo "  -> 挂载镜像并复制数据"
MOUNT_DIR=$(mktemp -d)
trap 'sudo umount "$MOUNT_DIR" 2>/dev/null; rmdir "$MOUNT_DIR" || true; sudo rm -rf "$INSTALL_ROOT"' EXIT
sudo mount -o loop $ROOTFS_IMG $MOUNT_DIR
sudo rsync -aHAX "$INSTALL_ROOT/" "$MOUNT_DIR/"
sudo umount $MOUNT_DIR
rmdir $MOUNT_DIR

echo "  -> 收缩文件系统到最小尺寸"
sudo e2fsck -f -y $ROOTFS_IMG
sudo resize2fs -M $ROOTFS_IMG

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