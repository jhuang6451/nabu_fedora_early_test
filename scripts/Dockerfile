# 使用官方的 Fedora 42 镜像作为基础
FROM fedora:42

# 更新 dnf 缓存并安装核心工具
# 将安装命令分成几步，并增加 -y 确认和错误排查步骤
RUN dnf makecache && \
    dnf install -y dnf-utils dnf-plugins-core qemu-user-static coreutils tar gzip curl && \
    dnf install -y dosfstools mtools e2fsprogs libguestfs-tools rpm-build cpio && \
    dnf install -y grub2-efi-aa64 grub2-efi-aa64-cdboot && \
    dnf install -y systemd-container findutils util-linux rsync && \
    dnf clean all
