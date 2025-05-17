#!/bin/bash
set -euo pipefail
trap 'cleanup' EXIT

# 用户需确认的变量
NTFS_PARTITION="/dev/sda2"   # 请根据lsblk结果修改
EXT4_PARTITION="/dev/sda1"   # 请根据lsblk结果修改
ISO_PATH="/mnt/ntfs/endeavourOS.iso"  # ISO在NTFS分区中的路径

cleanup() {
    echo "正在清理挂载点..."
    umount -l /mnt/ext4/dev/pts 2>/dev/null || true
    umount -l /mnt/ext4/dev 2>/dev/null || true
    umount -l /mnt/ext4/proc 2>/dev/null || true
    umount -l /mnt/ext4/sys 2>/dev/null || true
    umount -l /mnt/ext4 2>/dev/null || true
    umount -l /mnt/iso 2>/dev/null || true
    umount -l /mnt/ntfs 2>/dev/null || true
}

prepare_filesystem() {
    echo "=== 步骤1: 准备文件系统 ==="
    [ -b "$NTFS_PARTITION" ] || { echo "错误：NTFS分区不存在"; exit 1; }
    [ -b "$EXT4_PARTITION" ] || { echo "错误：EXT4分区不存在"; exit 1; }

    mkdir -p /mnt/{ntfs,ext4,iso}
    
    echo "挂载NTFS分区(只读)..."
    mount -t ntfs-3g -o ro,noexec,nosuid "$NTFS_PARTITION" /mnt/ntfs || {
        echo "NTFS挂载失败，尝试使用只读模式..."
        mount -t ntfs -o ro "$NTFS_PARTITION" /mnt/ntfs || {
            echo "致命错误：无法挂载NTFS分区"; exit 1
        }
    }

    echo "挂载EXT4分区..."
    mount "$EXT4_PARTITION" /mnt/ext4 || {
        echo "EXT4挂载失败，尝试修复..."
        fsck -y "$EXT4_PARTITION"
        mount "$EXT4_PARTITION" /mnt/ext4 || {
            echo "致命错误：无法挂载EXT4分区"; exit 1
        }
    }
}

extract_system() {
    echo "=== 步骤2: 处理ISO镜像 ==="
    [ -f "$ISO_PATH" ] || { echo "错误：ISO文件不存在"; exit 1; }

    echo "挂载ISO镜像..."
    mount -o loop,ro "$ISO_PATH" /mnt/iso || {
        echo "ISO挂载失败"; exit 1
    }

    SFS_PATH="/mnt/iso/arch/x86_64/airootfs.sfs"
    [ -f "$SFS_PATH" ] || { echo "错误：找不到airootfs.sfs"; exit 1; }

    echo "解压SquashFS系统..."
    if command -v unsquashfs &>/dev/null; then
        unsquashfs -f -d /mnt/ext4 "$SFS_PATH" || {
            echo "解压失败，尝试直接挂载..."
            modprobe squashfs || { echo "无法加载squashfs模块"; exit 1; }
            mount -t squashfs "$SFS_PATH" /mnt/ext4 || {
                echo "SquashFS挂载失败"; exit 1
            }
        }
    else
        echo "警告：未找到unsquashfs，尝试挂载方式"
        modprobe squashfs || { echo "无法加载squashfs模块"; exit 1; }
        mount -t squashfs "$SFS_PATH" /mnt/ext4 || {
            echo "SquashFS挂载失败"; exit 1
        }
    fi
}

configure_system() {
    echo "=== 步骤3: 系统配置 ==="
    echo "生成fstab..."
    mkdir -p /mnt/ext4/etc
    genfstab -U /mnt/ext4 > /mnt/ext4/etc/fstab

    echo "准备chroot环境..."
    mount --bind /dev /mnt/ext4/dev
    mount --bind /proc /mnt/ext4/proc
    mount --bind /sys /mnt/ext4/sys

    echo "开始chroot配置..."
    chroot /mnt/ext4 /bin/bash <<-'EOF'
    set -e
    echo "更新软件源..."
    pacman -Syy --noconfirm || {
        echo "尝试更换镜像..."
        reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
        pacman -Syy --noconfirm
    }

    echo "安装基础系统..."
    pacman -S --noconfirm base linux linux-firmware openssh sudo grub efibootmgr

    echo "配置本地化和时区..."
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

    echo "设置root密码："
    passwd

    echo "生成initramfs..."
    mkinitcpio -P

    echo "安装引导程序(根据实际情况调整)..."
    grub-install --target=i386-pc /dev/sda
    grub-mkconfig -o /boot/grub/grub.cfg

    echo "启用SSH..."
    systemctl enable sshd.service
EOF
}

main() {
    echo "=== EndeavourOS 安装脚本 ==="
    read -p "确认要开始安装吗？(y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1

    prepare_filesystem
    extract_system
    configure_system

    echo "=== 安装完成！==="
    read -p "是否现在重启？(y/N) " -n 1 -r
    [[ $REPLY =~ ^[Yy]$ ]] && reboot || echo "请手动重启"
}

main
