#!/bin/bash

set -e

# 定义变量
TAG="fedora-nabu-$(date +'%Y%m%d-%H%M')"
ROOTFS_PATH="artifacts/rootfs-artifact/fedora-42-nabu-rootfs.img"
ROOTFS_COMPRESSED_PATH="${ROOTFS_PATH}.tar.gz"
ESP_PATH="artifacts/esp-artifact/esp.img"

# 检查原始文件是否存在
if [ ! -f "$ROOTFS_PATH" ] || [ ! -f "$ESP_PATH" ]; then
    echo "Error: Artifacts not found!"
    exit 1
fi

# 将 rootfs img 文件压缩为 tar.gz
echo "Compressing ${ROOTFS_PATH}..."
# 使用 -C 选项来避免在压缩包中包含父目录结构
tar -czvf "$ROOTFS_COMPRESSED_PATH" -C "$(dirname "$ROOTFS_PATH")" "$(basename "$ROOTFS_PATH")"
echo "Compression successful: ${ROOTFS_COMPRESSED_PATH}"

# 检查压缩文件是否存在
if [ ! -f "$ROOTFS_COMPRESSED_PATH" ]; then
    echo "Error: Compressed rootfs file not found!"
    exit 1
fi

# 创建 Release 并上传压缩后的 rootfs 和 esp 文件
echo "Creating GitHub release ${TAG}..."
gh release create "$TAG" \
    --title "Fedora 42 for Mi Pad 5 (nabu) - ${TAG}" \
    --notes "Automated build of Fedora 42 for Xiaomi Pad 5 (nabu). Includes compressed rootfs (tar.gz) and ESP image." \
    "$ROOTFS_COMPRESSED_PATH" \
    "$ESP_PATH"

echo "Release ${TAG} created successfully with assets."