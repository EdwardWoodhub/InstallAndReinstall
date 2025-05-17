#!/bin/bash
set -euo pipefail
trap 'cleanup' EXIT

# ================= 用户配置区域 =================
NTFS_PARTITION="/dev/sda2"           # 使用lsblk确认NTFS分区
EXT4_PARTITION="/dev/sda1"           # 使用lsblk确认EXT4分区
MOUNT_DIR="/root/system"             # 系统挂载点
NTFS_MOUNT="/root/ntfs"              # NTFS挂载点
ISO_NAME="endeavouros.iso"           # ISO文件名
ISO_PATH="$NTFS_MOUNT/iso/$ISO_NAME" # ISO完整路径
ISO_URL="https://mirror.alpix.eu/endeavouros/iso/EndeavourOS_Mercury-Neo-2025.03.19.iso"
SQUASHFS_TOOLS_URL="https://archive.archlinux.org/packages/s/s/squashfs-tools/squashfs-tools-4.6.1-1-x86_64.pkg.tar.zst"
# ================================================

cleanup() {
    echo "执行清理操作..."
    for mountpoint in $MOUNT_DIR/dev/pts $MOUNT_DIR/dev $MOUNT_DIR/proc $MOUNT_DIR/sys $MOUNT_DIR $NTFS_MOUNT /mnt/iso; do
        umount -l $mountpoint 2>/dev/null || true
    done
    rm -rf /tmp/squashfs-tools
}

prepare_environment() {
    echo "=== 环境准备 ==="
    modprobe loop || true
    modprobe squashfs || true
    modprobe fuse || true
}

install_squashfs_tools() {
    echo "=== 安装squashfs工具 ==="
    local TMP_DIR="/tmp/squashfs-tools"
    mkdir -p $TMP_DIR

    echo "下载squashfs-tools..."
    if ! curl -L -o "$TMP_DIR/pkg.tar.zst" "$SQUASHFS_TOOLS_URL"; then
        echo "错误：无法下载squashfs-tools，尝试编译安装..."
        build_squashfs_from_source
        return
    fi

    echo "解压软件包..."
    tar -xf "$TMP_DIR/pkg.tar.zst" -C $TMP_DIR

    echo "部署二进制文件..."
    cp $TMP_DIR/usr/bin/*squashfs /usr/local/bin/
    cp -r $TMP_DIR/usr/lib/ /usr/local/
    ldconfig

    if ! unsquashfs -version; then
        echo "错误：squashfs-tools安装失败！"
        exit 1
    fi
}

build_squashfs_from_source() {
    echo "=== 从源码编译squashfs-tools ==="
    local SRC_DIR="/tmp/squashfs-src"
    mkdir -p $SRC_DIR

    echo "下载源码..."
    curl -L https://github.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz | tar xz -C $SRC_DIR

    echo "编译安装..."
    cd $SRC_DIR/squashfs-tools-4.6.1/squashfs-tools
    make -j$(nproc)
    cp unsquashfs /usr/local/bin/
}

download_iso() {
    echo "=== 下载ISO文件 ==="
    mkdir -p "$(dirname "$ISO_PATH")"

    echo "下载地址：$ISO_URL"
    if ! curl -L -o "$ISO_PATH.part" -C - "$ISO_URL"; then
        echo "错误：ISO下载失败！"
        echo "可能原因："
        echo "1. 网络连接异常"
        echo "2. 磁盘空间不足"
        exit 1
    fi
    mv "$ISO_PATH.part" "$ISO_PATH"
}

mount_filesystems() {
    echo "=== 挂载文件系统 ==="
    [ -b "$NTFS_PARTITION" ] || { echo "错误：NTFS分区不存在"; exit 1; }
    [ -b "$EXT4_PARTITION" ] || { echo "错误：EXT4分区不存在"; exit 1; }
    mkdir -p $NTFS_MOUNT
    echo "处理NTFS分区..."
    if ! mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT" 2>/dev/null; then
        echo "检测到NTFS错误，尝试修复..."
        ntfsfix  "$NTFS_PARTITION"
        mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT" || {
            echo "致命错误：无法挂载NTFS分区"
            exit 1
        }
    fi

    echo "检查ISO文件..."
    if [ ! -f "$ISO_PATH" ]; then
        echo "未找到ISO文件，开始下载..."
        umount "$NTFS_MOUNT"
        mount -t ntfs-3g -o rw "$NTFS_PARTITION" "$NTFS_MOUNT"
        download_iso
        umount "$NTFS_MOUNT"
        mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT"
    fi

    echo "挂载EXT4系统分区..."
    fsck -y "$EXT4_PARTITION" || true
    mount "$EXT4_PARTITION" "$MOUNT_DIR" || {
        echo "无法挂载EXT4分区"
        exit 1
    }
}

extract_system() {
    echo "=== 解压系统文件 ==="
    if ! command -v unsquashfs &>/dev/null; then
        install_squashfs_tools
    fi

    echo "挂载ISO镜像..."
    mount -o loop,ro "$ISO_PATH" /mnt/iso

    local SFS_PATH="/mnt/iso/arch/x86_64/airootfs.sfs"
    [ -f "$SFS_PATH" ] || { echo "错误：找不到airootfs.sfs"; exit 1; }

    echo "解压系统..."
    unsquashfs -f -d "$MOUNT_DIR" "$SFS_PATH" || {
        echo "解压失败，尝试挂载方式..."
        modprobe squashfs
        mount -t squashfs "$SFS_PATH" "$MOUNT_DIR"
    }
}

configure_system() {
    echo "=== 系统配置 ==="
    echo "生成fstab..."
    genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"

    echo "准备chroot环境..."
    mount --bind /dev "$MOUNT_DIR/dev"
    mount --bind /proc "$MOUNT_DIR/proc"
    mount --bind /sys "$MOUNT_DIR/sys"

    echo "执行chroot配置..."
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
set -e
echo "初始化Pacman密钥..."
pacman-key --init
pacman-key --populate

echo "配置镜像源..."
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacman -Syy --noconfirm

echo "安装基础系统..."
pacman -S --noconfirm base linux linux-firmware grub openssh sudo

echo "配置本地化..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "设置root密码："
passwd

echo "生成initramfs..."
mkinitcpio -P

echo "安装引导程序..."
grub-install --target=i386-pc "$(lsblk -no pkname $EXT4_PARTITION)"
grub-mkconfig -o /boot/grub/grub.cfg

echo "启用SSH服务..."
systemctl enable sshd.service

echo "安装云环境支持..."
pacman -S --noconfirm cloud-init qemu-guest-agent
systemctl enable cloud-init.service
systemctl enable qemu-guest-agent.service
EOF
}

main() {
    echo "======= EndeavourOS 安装脚本 ======="
    prepare_environment
    mount_filesystems
    extract_system
    configure_system

    echo "=== 安装完成！ ==="
    read -p "是否立即重启？(y/N) " -n 1 -r
    [[ $REPLY =~ ^[Yy]$ ]] && reboot || echo "请手动执行重启命令"
}

# 执行主程序
main
