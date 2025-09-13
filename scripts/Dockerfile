# 使用官方的 Fedora 42 镜像作为基础
FROM fedora:42

# 安装构建 aarch64 rootfs 所需的核心工具
RUN dnf install -y \
    dnf-utils \
    dnf-plugins-core \
    qemu-user-static \
    coreutils \
    tar \
    gzip \
    dosfstools \
    grub2-efi-aa64 \
    grub2-efi-aa64-cdboot \
    mtools \
    e2fsprogs \
    libguestfs-tools \
    rpm-build \
    cpio \
    systemd-container \
    findutils \
    util-linux \
    rsync \
    curl \
    && dnf clean all
