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

echo "Copying first-boot scripts into rootfs..."
# 确保目标目录存在
mkdir -p "$ROOTFS_DIR/usr/local/bin"
# 复制交互式配置脚本
cp ./scripts/post_install.sh "$ROOTFS_DIR/usr/local/bin/post_install.sh"
chmod +x "$ROOTFS_DIR/usr/local/bin/post_install.sh"

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



# ==========================================================================
# --- 安装必要的软件包 ---
# ==========================================================================
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
    vim \
    glibc-langpack-en \
    systemd-resolved \
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
# --------------------------------------------------------------------------



# ==========================================================================
# --- 创建并启用 tqftpserv, rmtfs 和 qbootctl 服务 ---
# ==========================================================================
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
# --------------------------------------------------------------------------



# ==========================================================================
# --- 创建 /etc/fstab ---
# ==========================================================================
echo 'Creating /etc/fstab for automatic partition mounting...'
cat <<EOF > "/etc/fstab"
# /etc/fstab: static file system information.
LABEL=fedora_root  /              ext4    defaults,x-systemd.device-timeout=0   1 1
LABEL=ESPNABU          /boot/efi      vfat    umask=0077,shortname=winnt            0 2
EOF
# --------------------------------------------------------------------------



# ==========================================================================
# --- 创建 dracut 配置以支持 UKI 生成 ---
# ==========================================================================
echo 'Creating DYNAMIC dracut config for automated UKI generation...'
mkdir -p "/etc/dracut.conf.d/"
cat <<EOF > "/etc/dracut.conf.d/99-nabu-uki.conf"
# This is a dynamically-aware configuration for dracut.
uefi=yes
uefi_stub=/usr/lib/systemd/boot/efi/linuxaarch64.efi.stub

# 使用 dracut 内部的 '${kernel}' 变量
devicetree="/usr/lib/modules/${kernel}/dtb/qcom/sm8150-xiaomi-nabu.dtb"

# --- Robust Kernel Command Line ---
# uefi_cmdline is the specific option for UKIs.
uefi_cmdline="root=LABEL=fedora_root rw quiet"
# For some reason, This doesn't work. So I also add kernel_cmdline below.
# kernel_cmdline is a more general option that also gets included.
EOF
echo 'Dracut config created.'
# --------------------------------------------------------------------------



# ==========================================================================
# --- 使用 kernel-install 生成初始 UKI ---
# ==========================================================================

# --- 1. 检测内核版本 ---
echo 'Detecting installed kernel version for initial UKI generation...'
KERNEL_VERSION=$(ls /lib/modules | sort -rV | head -n1)
if [ -z "$KERNEL_VERSION" ]; then
    echo 'ERROR: No kernel version found inside chroot!' >&2
    exit 1
fi
echo "Detected kernel version for kernel-install: $KERNEL_VERSION"

# --- 2. 配置 kernel-install ---
echo 'Configuring kernel-install to generate UKIs...'
mkdir -p "/etc/kernel/"
cat <<EOF > "/etc/kernel/install.conf"
# Tell kernel-install to use dracut as the UKI generator.
uki_generator=dracut
EOF

# --- 3. 运行一次 kernel-install 来生成 UKI ---
echo 'Running kernel-install to generate the initial UKI...'
kernel-install add "$KERNEL_VERSION" "/boot/vmlinuz-$KERNEL_VERSION"
# --------------------------------------------------------------------------



# # ==================================================================================================
# # --- temporary fix (because of dracut conf issue): 动态查找 UKI 并创建健壮的 system-boot 引导项 ---
# # ==================================================================================================
# echo 'Dynamically locating the generated UKI file...'
# # 使用 find 查找由 kernel-install 生成的、包含特定内核版本的 UKI 文件
# UKI_FILE_PATH=$(find "/boot/efi/EFI/Linux/" -name "linux-${KERNEL_VERSION}-*.efi" -print -quit)

# if [ -z "$UKI_FILE_PATH" ]; then
#     echo 'CRITICAL ERROR: Could not find the generated UKI file!' >&2
#     exit 1
# fi

# # --- 从完整路径中提取文件名 ---
# UKI_BASENAME=$(basename "$UKI_FILE_PATH")
# echo "Found UKI: $UKI_BASENAME"

# echo 'Creating a robust boot loader entry...'
# ENTRY_DIR="/boot/efi/loader/entries"
# # 我们使用一个固定的、可预测的文件名，以便 'loader.conf' 可以轻松地将其设为默认
# ENTRY_FILE="${ENTRY_DIR}/fedora-nabu.conf" 

# mkdir -p "$ENTRY_DIR"

# cat <<EOF > "$ENTRY_FILE"
# # Generated by Fedora-Nabu build script
# title      Fedora Linux for Xiaomi Pad 5 (Nabu)
# efi        /EFI/Linux/${UKI_BASENAME}
# options    root=LABEL=fedora_root rw quiet
# EOF

# echo "Boot loader entry created at '$ENTRY_FILE'"
# # ==================================================================================================
# # --- temporary fix end ---
# # ==================================================================================================



# ==========================================================================
# --- 创建 systemd-boot 的 loader.conf ---
# ==========================================================================
echo 'Creating systemd-boot loader configuration...'
mkdir -p "/boot/efi/loader/"
cat <<EOF > "/boot/efi/loader/loader.conf"
# See loader.conf(5) for details
timeout 6
console-mode max
default fedora-*
EOF
#TODO : 这里的 default 需要动态设置为上面生成的那个 entry 文件
# --------------------------------------------------------------------------



# ==========================================================================
# --- 新增部分：强制包含关键的存储驱动 ---
# ==========================================================================
echo 'Creating dracut config to force-include UFS storage drivers...'
# 这是一个关键的健壮性措施，确保 initrd 总是包含启动所需的 UFS 驱动，
# 避免 dracut 在 chroot 环境中因无法检测到目标硬件而遗漏它们。
cat <<EOF > "/etc/dracut.conf.d/98-nabu-storage.conf"
# Force-add essential drivers for Qualcomm UFS storage on Nabu.
add_drivers+=" ufs_qcom ufshcd_platform "
EOF
echo 'UFS driver config for dracut created.'
# ==========================================================================



# ==========================================================================
# --- 配置 zram 交换分区 ---
# ==========================================================================
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
# ==========================================================================



# ==========================================================================
# --- 集成首次启动服务 ---
# ==========================================================================
# --- 1. 创建并启用自动扩展文件系统服务 (非交互式) ---
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

    
# # 2. --- 创建并启用交互式配置服务 ---
# echo 'Creating interactive first-boot setup service...'
# cat <<'EOF' > "/etc/systemd/system/first-boot-setup.service"
# [Unit]
# Description=Interactive First-Boot Setup
# # 在 resize 服务之后，在图形界面之前运行
# After=resize-rootfs.service
# Before=graphical.target

# [Service]
# Type=oneshot
# ExecStart=/usr/local/bin/post_install.sh
# # 关键: 将服务的输入输出连接到物理控制台
# StandardInput=tty
# StandardOutput=tty
# StandardError=tty
# RemainAfterExit=no

# [Install]
# WantedBy=default.target
# EOF
# # 启用服务
# systemctl enable first-boot-setup.service

echo 'First-boot services created and enabled.'
#TODO: 交互式配置服务暂时无法正常运行
# --------------------------------------------------------------------------



# ==========================================================================
# --- 添加创建者签名到 /etc/os-release ---
# ==========================================================================
echo 'Adding creator signature to /etc/os-release...'
echo 'BUILD_CREATOR="jhuang6451"' >> "/etc/os-release"
# --------------------------------------------------------------------------



# ===========================================================================================
# --- temporary fix (because interactive post-install script won't work) 临时用户添加部分 ---
# ===========================================================================================
echo 'Adding temporary user "user" with sudo privileges...'

# 1. 创建名为 'user' 的用户，并将其加入 'wheel' 组。
#    --create-home (-m) 确保创建用户的主目录 /home/user。
#    --groups (-G) wheel 是在 Fedora/RHEL/CentOS 上授予 sudo 权限的标准做法。
useradd --create-home --groups wheel user
if [ $? -eq 0 ]; then
    echo 'User "user" created and added to "wheel" group successfully.'
else
    echo 'ERROR: Failed to create user "user".' >&2
    exit 1
fi

# 2. 以非交互方式为用户 'user' 设置密码 'fedora'。
#    使用 'chpasswd' 是在脚本中设置密码最安全、最直接的方法。
echo 'user:fedora' | chpasswd
if [ $? -eq 0 ]; then
    echo 'Password for "user" has been set to "fedora".'
else
    echo 'ERROR: Failed to set password for "user".' >&2
    exit 1
fi

# 3. 确保 'wheel' 组拥有 sudo 权限。
#    这在标准的 Fedora 系统中是默认配置，但为了确保万无一失，我们显式地创建
#    一个 sudoers 配置文件。这样可以避免主 /etc/sudoers 文件被意外修改的风险。
#    注意：sudoers 配置文件必须有严格的权限 (0440)。
SUDOERS_FILE="/etc/sudoers.d/99-wheel-user"
echo '%wheel ALL=(ALL) ALL' > "$SUDOERS_FILE"
chmod 0440 "$SUDOERS_FILE"
echo "Sudo access for group 'wheel' has been configured via $SUDOERS_FILE."
# ===========================================================================================
# --- 临时用户添加结束 ---
#TODO: remove this temporary user after interactive post-install script is fixed
# ===========================================================================================



# ==========================================================================
# --- 清理 DNF 缓存以节省空间 ---
# ==========================================================================
echo 'Cleaning dnf cache...'
dnf clean all
# --------------------------------------------------------------------------



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