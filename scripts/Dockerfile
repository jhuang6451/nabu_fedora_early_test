# 使用官方的 Fedora 42 镜像作为基础
FROM fedora:42

# 定义构建所需的变量
ARG FEDORA_VERSION=42
ARG TARGET_ARCH=aarch64

# 步骤 1: 导入目标架构的 GPG 密钥
# 我们需要 GPG 密钥来验证 aarch64 软件包的签名
RUN dnf install -y fedora-gpg-keys && dnf clean all

# 步骤 2: 添加 aarch64 架构的软件仓库配置文件
# 这会让 DNF 知道去哪里查找 aarch64 的软件包
RUN echo $'[fedora-aarch64]\n\
name=Fedora ${FEDORA_VERSION} - ${TARGET_ARCH}\n\
metalink=https://mirrors.fedoraproject.org/metalink?repo=fedora-${FEDORA_VERSION}&arch=${TARGET_ARCH}\n\
enabled=1\n\
gpgcheck=1\n\
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${FEDORA_VERSION}-primary' > /etc/yum.repos.d/fedora-aarch64.repo

RUN echo $'[updates-aarch64]\n\
name=Fedora ${FEDORA_VERSION} - ${TARGET_ARCH} - Updates\n\
metalink=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f${FEDORA_VERSION}&arch=${TARGET_ARCH}\n\
enabled=1\n\
gpgcheck=1\n\
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-${FEDORA_VERSION}-primary' > /etc/yum.repos.d/updates-aarch64.repo


# 更新 dnf 缓存并安装核心工具
# 将安装命令分成几步，并增加 -y 确认和错误排查步骤
RUN dnf makecache && \
    dnf install -y dnf-utils dnf-plugins-core qemu-user-static coreutils tar gzip curl && \
    dnf install -y dosfstools mtools e2fsprogs libguestfs-tools rpm-build cpio && \
    dnf install -y grub2-tools grub2-efi-aarch64.aarch64 grub2-efi-aarch64-cdboot.aarch64 && \
    dnf install -y systemd-container findutils util-linux rsync && \
    dnf clean all
