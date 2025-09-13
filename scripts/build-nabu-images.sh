#!/bin/bash

############################################################################################################################################
## Name: build-nabu-images.sh (Multi-Stage)                                                                                               ##
## Author: jhuang6451 <xplayerhtz123@outlook.com>                                                                                         ##
## Time: 2025-9-13                                                                                                                        ##
## Description:                                                                                                                           ##
##  This script supports multi-stage builds for the nabu Fedora image.                                                                    ##
##  Use BUILD_STAGE env var to select a stage:                                                                                            ##
##    - build_base_rootfs: Creates a minimal rootfs image without a desktop environment.                                                  ##
##    - install_desktop:   Installs GNOME desktop into an existing rootfs image.                                                          ##
##    - build_esp:         Creates an ESP image using an existing rootfs image.                                                           ##
############################################################################################################################################

set -ex # 如果任何命令失败，则立即退出脚本，并打印执行的命令

# --- 脚本配置 ---
TIMESTAMP=${TIMESTAMP:-$(date +%Y%m%d)}
COPR_REPOS=(
    "jhuang6451/nabu_fedora_packages_uefi"
    "onesaladleaf/pocketblue"
    "onesaladleaf/mobility-common"
)
FEDORA_RELEASE="42"
ROOTFS_IMG="fedora-nabu-rootfs-${TIMESTAMP}.img"
ESP_IMG="nabu-esp-${TIMESTAMP}.img"
ESP_SIZE="512M"
REFIND_SOURCE_DIR="${REFIND_SOURCE_DIR:-./refind_src}"

# --- 函数定义 ---

# --- 依赖检查 ---
check_deps() {
    echo "INFO: 正在检查所需工具..."
    # 将依赖项按阶段分组，避免在每个阶段都安装所有工具
    local deps=("$@")
    for cmd in "${deps[@]}"; do
        if ! command -v $cmd &> /dev/null; then
            echo "错误: 命令 '$cmd' 未找到。请安装必要的软件包。"
            exit 1
        fi
    done
    echo "INFO: 所有必需工具均已就绪。"
}

# --- 阶段函数: 构建基础 Rootfs ---
build_base_rootfs() {
    echo "##############################################"
    echo "### 阶段: 构建基础 Rootfs"
    echo "##############################################"

    INSTALL_ROOT=$(mktemp -d)
    trap 'sudo rm -rf "$INSTALL_ROOT"' EXIT

    echo "INFO: 创建临时Rootfs目录: $INSTALL_ROOT"
    
    # --- 准备 chroot 环境 (省略了部分重复的 echo) ---
    sudo mkdir -p "$INSTALL_ROOT/usr/bin" && sudo cp /usr/bin/qemu-aarch64-static "$INSTALL_ROOT/usr/bin/"
    sudo mkdir -p "$INSTALL_ROOT/etc" && sudo cp /etc/resolv.conf "$INSTALL_ROOT/etc/"
    sudo mkdir -p "$INSTALL_ROOT/etc/yum.repos.d/"
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
    sudo mkdir -p "$INSTALL_ROOT/etc/pki/rpm-gpg/"
    sudo curl -o "$INSTALL_ROOT/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${FEDORA_RELEASE}-primary" "https://src.fedoraproject.org/rpms/fedora-repos/raw/rawhide/f/RPM-GPG-KEY-fedora-${FEDORA_RELEASE}-primary"

    for repo in "${COPR_REPOS[@]}"; do
        COPR_OWNER=$(echo $repo | cut -d'/' -f1); COPR_PROJECT=$(echo $repo | cut -d'/' -f2)
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
    packages=(
        "fedora-repos"
        "xiaomi-nabu-firmware" "xiaomi-nabu-audio"
        "grub2-efi-aa64" "grub2-efi-aa64-modules"
        "systemd-oomd-defaults" "systemd-resolved"
        "glibc-langpack-en" "fuse"
        "qbootctl" "tqftpserv" "pd-mapper" "rmtfs" "qrtr"
        "NetworkManager-tui" "git" "grubby" "vim" "sudo"
        "kernel-sm8150"
    )
    sudo dnf -v -y --installroot="$INSTALL_ROOT" --releasever=$FEDORA_RELEASE --forcearch=aarch64 \
        --exclude dracut-config-rescue --setopt=install_weak_deps=False --setopt=tsflags=noscripts \
        install "${packages[@]}"
    sudo systemd-nspawn -D "$INSTALL_ROOT" bash -c 'rpm -qa | xargs -n 100 dnf -y reinstall'

    # --- chroot 环境配置 ---
    # ... (注入服务、启用服务、设置密码等，这部分代码不变)
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
    sudo systemd-nspawn -D "$INSTALL_ROOT" systemctl enable tqftpserv.service rmtfs.service resize-rootfs.service qbootctl-mark-boot-successful.service
    echo 'root:fedora' | sudo chpasswd --root $INSTALL_ROOT
    echo "警告: 已设置默认root密码为 'fedora'。"

    # --- 清理 chroot 环境 ---
    sudo systemd-nspawn -D "$INSTALL_ROOT" /usr/bin/dnf clean all
    sudo rm -rf "$INSTALL_ROOT/var/log/*"; sudo rm -f "$INSTALL_ROOT/usr/bin/qemu-aarch64-static"; sudo rm -f "$INSTALL_ROOT/etc/resolv.conf"

    # --- 创建最终镜像文件 ---
    ROOTFS_SIZE_BYTES=$(sudo du -sb "$INSTALL_ROOT" | awk '{print $1}')
    ROOTFS_FINAL_SIZE=$((ROOTFS_SIZE_BYTES * 12 / 10)) # 增加20%的额外空间
    truncate -s $ROOTFS_FINAL_SIZE $ROOTFS_IMG
    mkfs.ext4 -L "fedora_root" $ROOTFS_IMG
    MOUNT_DIR=$(mktemp -d); trap 'sudo umount "$MOUNT_DIR" 2>/dev/null; rmdir "$MOUNT_DIR" || true; sudo rm -rf "$INSTALL_ROOT"' EXIT
    sudo mount -o loop $ROOTFS_IMG $MOUNT_DIR
    sudo rsync -aHAX "$INSTALL_ROOT/" "$MOUNT_DIR/"
    sudo umount $MOUNT_DIR; rmdir $MOUNT_DIR
    sudo e2fsck -f -y $ROOTFS_IMG
    sudo resize2fs -M $ROOTFS_IMG
    echo "INFO: 基础 Rootfs 构建完成: ${ROOTFS_IMG}"
}

# --- 阶段函数: 安装桌面环境 ---
install_desktop() {
    echo "##############################################"
    echo "### 阶段: 安装桌面环境到 ${ROOTFS_IMG}"
    echo "##############################################"

    if [ ! -f "$ROOTFS_IMG" ]; then
        echo "错误: Rootfs 镜像 '$ROOTFS_IMG' 未找到！" >&2; exit 1
    fi
    
    MOUNT_DIR=$(mktemp -d)
    trap 'sudo guestunmount "$MOUNT_DIR" 2>/dev/null || true; rmdir "$MOUNT_DIR" || true' EXIT

    echo "INFO: 挂载基础镜像..."
    sudo guestmount -a $ROOTFS_IMG -m /dev/sda $MOUNT_DIR

    echo "INFO: 准备 chroot 环境..."
    sudo cp /usr/bin/qemu-aarch64-static "$MOUNT_DIR/usr/bin/"
    sudo cp /etc/resolv.conf "$MOUNT_DIR/etc/"
    
    echo "INFO: 在 chroot 环境中安装 GNOME 桌面..."
    # 为GDM添加登录用户
    sudo systemd-nspawn -D "$MOUNT_DIR" useradd -m -G wheel fedora
    echo 'fedora:fedora' | sudo chpasswd --root $MOUNT_DIR
    echo "警告: 已创建用户 'fedora'，密码 'fedora'。"
    # 安装桌面包组并启用GDM
    sudo systemd-nspawn -D "$MOUNT_DIR" dnf -y install @gnome-desktop gnome-terminal nautilus gnome-software firefox
    sudo systemd-nspawn -D "$MOUNT_DIR" systemctl enable gdm.service

    echo "INFO: 清理环境..."
    sudo systemd-nspawn -D "$MOUNT_DIR" dnf clean all
    sudo rm -f "$MOUNT_DIR/usr/bin/qemu-aarch64-static"; sudo rm -f "$MOUNT_DIR/etc/resolv.conf"
    
    echo "INFO: 卸载镜像并进行收缩..."
    sudo guestunmount $MOUNT_DIR
    sudo e2fsck -f -y $ROOTFS_IMG
    sudo resize2fs -M $ROOTFS_IMG
    echo "INFO: 桌面环境安装完成。"
}

# --- 阶段函数: 构建ESP ---
build_esp() {
    echo "##############################################"
    echo "### 阶段: 构建 ESP ($ESP_IMG)"
    echo "##############################################"

    if [ ! -f "$ROOTFS_IMG" ]; then
        echo "错误: Rootfs 镜像 '$ROOTFS_IMG' 未找到！" >&2; exit 1
    fi
    
    ESP_WORKDIR=$(mktemp -d)
    trap 'rm -rf "$ESP_WORKDIR" boot grub2-efi-aa64-*.rpm' EXIT
    mkdir -p $ESP_WORKDIR/EFI/{BOOT,fedora} $ESP_WORKDIR/fedora

    echo "INFO: 下载并提取 GRUB aarch64 EFI..."
    dnf download --quiet --arch=aarch64 grub2-efi-aa64
    rpm2cpio grub2-efi-aa64-*.rpm | cpio -idmv &>/dev/null
    GRUB_EFI_PATH="./boot/efi/EFI/fedora/grubaa64.efi"

    echo "INFO: 从 ${ROOTFS_IMG} 中提取内核和DTB..."
    MOUNT_DIR=$(mktemp -d)
    trap 'sudo guestunmount "$MOUNT_DIR" 2>/dev/null; rmdir "$MOUNT_DIR"; rm -rf "$ESP_WORKDIR" boot grub2-efi-aa64-*.rpm' EXIT
    sudo guestmount -a $ROOTFS_IMG -r -m /dev/sda $MOUNT_DIR
    KERNEL_VERSION=$(basename $(ls $MOUNT_DIR/boot/vmlinuz-*)); KERNEL_VERSION=${KERNEL_VERSION#vmlinuz-}
    cp "$MOUNT_DIR/boot/vmlinuz-${KERNEL_VERSION}" "$ESP_WORKDIR/fedora/Image"
    cp "$MOUNT_DIR/usr/lib/modules/${KERNEL_VERSION}/dtb/qcom/sm8150-xiaomi-nabu.dtb" "$ESP_WORKDIR/fedora/sm8150-xiaomi-nabu.dtb"
    sudo guestunmount $MOUNT_DIR; rmdir $MOUNT_DIR

    ROOTFS_UUID=$(sudo tune2fs -l $ROOTFS_IMG | grep 'Filesystem UUID' | awk '{print $3}')
    truncate -s $ESP_SIZE $ESP_IMG; mkfs.vfat -n "ESP" $ESP_IMG > /dev/null
    ESP_UUID=$(sudo blkid $ESP_IMG | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')

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

    if [ -f "${REFIND_SOURCE_DIR}/refind_aa64.efi" ]; then
        echo "INFO: 检测到 rEFInd, 将安装 rEFInd 作为主引导器。"
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
        echo "INFO: 未检测到 rEFInd, 将安装 GRUB 作为主引导器。"
        cp "$GRUB_EFI_PATH" "$ESP_WORKDIR/EFI/BOOT/BOOTAA64.EFI"
        echo "$GRUB_CFG_CONTENT" > "$ESP_WORKDIR/EFI/BOOT/grub.cfg"
    fi

    echo "INFO: 正在将所有文件写入ESP镜像: ${ESP_IMG}"
    mcopy -s -i $ESP_IMG $ESP_WORKDIR/* ::
    
    rm -rf $ESP_WORKDIR boot grub2-efi-aa64-*.rpm
    trap - EXIT
    echo "INFO: ESP 构建完成: ${ESP_IMG}"
}

# --- 主逻辑：根据 BUILD_STAGE 执行不同函数 ---
#
# 将此部分移动到所有函数定义之后，以确保函数在被调用前已被解析。
#
case "$BUILD_STAGE" in
    build_base_rootfs)
        check_deps sudo dnf truncate mkfs.ext4 guestmount guestunmount rsync systemd-nspawn curl xargs tune2fs e2fsck resize2fs
        build_base_rootfs
        ;;
    install_desktop)
        check_deps sudo guestmount guestunmount systemd-nspawn e2fsck resize2fs
        install_desktop
        ;;
    build_esp)
        check_deps dnf guestmount guestunmount rpm2cpio cpio mcopy blkid tune2fs
        build_esp
        ;;
    *)
        echo "错误: 未知的 BUILD_STAGE: '$BUILD_STAGE'"
        echo "有效选项为: build_base_rootfs, install_desktop, build_esp"
        exit 1
        ;;
esac