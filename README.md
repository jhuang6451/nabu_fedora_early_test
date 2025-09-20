# Fedora for Nabu

English | [Simplified-Chinese](./docs/README.zh.md)

This repository contains a set of scripts and GitHub Actions workflows to build a custom Fedora 42 image for the Xiaomi Nabu device (aarch64). The build process produces a bootable root filesystem and an EFI System Partition (ESP) image.

## Features

*   **Fedora 42:** Based on the latest Fedora release.
*   **aarch64:** Built for the ARM64 architecture.
*   **Graphical Environment:** (#TODO) Includes a standard graphical desktop environment.
*   **systemd-boot:** Uses `systemd-boot` boot manager.
*   **Unified Kernel Image (UKI):** Generates a UKI for a secure and streamlined boot process.

## How it Works

The build process is divided into two main stages, orchestrated by two separate GitHub Actions workflows:

1.  **Build Builder Image:** The `1-build-builder-image.yml` workflow builds a Docker container image that serves as the build environment. This image contains all the necessary tools and dependencies to create the Fedora image. The resulting container is pushed to the GitHub Container Registry.

2.  **Build Fedora for Nabu:** The `2-build-fedora-nabu.yml` workflow uses the builder image to perform the main build. This workflow consists of the following steps:
    *   **Create Rootfs:** The `2_create_rootfs.sh` script bootstraps a minimal Fedora 42 system, installs a graphical environment, and configures it for the Nabu device. This includes setting up custom services, fstab, and dracut for UKI generation.
    *   **Create ESP:** The `3_create_esp.sh` script creates the EFI System Partition (ESP) image, installs `systemd-boot`, and copies the bootloader configuration and UKIs from the rootfs.
    *   **Create Release:** A final job creates a new GitHub Release and uploads the generated `fedora-42-nabu-rootfs.img` and `esp.img` files as release assets.