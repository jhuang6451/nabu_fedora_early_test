# 使用官方的 Fedora 42 镜像作为基础
FROM fedora:42

# 安装构建 aarch64 rootfs 所需的核心工具
RUN dnf install -y \
    dnf-utils \
    qemu-user-static \
    binfmt-support \
    coreutils \
    tar \
    gzip \
    dosfstools \
    grub2-efi-aa64 \
    grub2-efi-aa64-cdboot \
    mtools \
    && dnf clean all

# 设置 aarch64 模拟环境
RUN /usr/sbin/update-binfmts --enable qemu-aarch64