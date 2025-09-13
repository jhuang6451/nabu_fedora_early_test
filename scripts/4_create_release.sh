#!/bin/bash

set -e

# 定义变量
TAG="fedora-nabu-$(date +'%Y%m%d-%H%M')"
ROOTFS_PATH="artifacts/rootfs-artifact/fedora-42-nabu-rootfs.tar.gz"
ESP_PATH="artifacts/esp-artifact/esp.img"

# 检查文件是否存在
if [ ! -f "$ROOTFS_PATH" ] || [ ! -f "$ESP_PATH" ]; then
    echo "Error: Artifacts not found!"
    exit 1
fi

# 创建 Release 并上传文件
gh release create "$TAG" \
    --title "Fedora 42 for Mi Pad 5 (nabu) - ${TAG}" \
    --notes "Automated build of Fedora 42 for Xiaomi Pad 5 (nabu). Includes rootfs and ESP image." \
    "$ROOTFS_PATH" \
    "$ESP_PATH"

echo "Release ${TAG} created successfully with assets."