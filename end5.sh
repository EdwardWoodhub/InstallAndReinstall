#!/bin/bash
set -euo pipefail
trap 'cleanup' EXIT

# ================= 用户配置区域 =================
NTFS_PARTITION="/dev/sda2"           # 使用 lsblk 确认NTFS分区
EXT4_PARTITION="/dev/sda1"           # 使用 lsblk 确认EXT4分区
MOUNT_DIR="/root/system"             # 系统挂载点
NTFS_MOUNT="/root/ntfs"              # NTFS挂载点
ISO_NAME="endeavouros.iso"           # ISO文件名
ISO_PATH="$NTFS_MOUNT/iso/$ISO_NAME" # ISO完整路径
ISO_URL="https://mirror.alpix.eu/endeavouros/iso/EndeavourOS_Mercury-Neo-2025.03.19.iso"
# ================================================

cleanup() { /* 保持不变 */ }

check_network() { /* 保持不变 */ }

check_dependencies() {
    echo "=== 检查依赖项 ==="
    local required=(
        "mount" "lsblk" "fsck" "ntfsfix" 
        "genfstab" "modprobe" "cp" "ping"
        "curl" "gzip" "wget" "reflector"
    )
    local missing=()
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo "错误：缺少必要命令 - ${missing[*]}"
        exit 1
    fi
}

prepare_environment() { /* 保持不变 */ }

mount_ntfs() { /* 保持不变 */ }

download_iso() { /* 保持不变 */ }

mount_ext4() { /* 保持不变 */ }

extract_system() { /* 保持不变 */ }

configure_mirrors() {
    echo "=== 动态生成欧洲镜像源 ==="
    reflector \
        --verbose \
        --country France,Germany,Netherlands,Sweden \
        --protocol https \
        --latest 5 \
        --sort rate \
        --save "$MOUNT_DIR/etc/pacman.d/mirrorlist"
    
    # 添加EndeavourOS专用源
    cat >> "$MOUNT_DIR/etc/pacman.d/mirrorlist" <<'EOL'
## EndeavourOS 欧洲源
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
EOL
}

initialize_keyring() {
    echo "=== 强化密钥初始化 ==="
    # 安装必要依赖
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
pacman -Syy --noconfirm --needed \
    gnupg gpgme libassuan libgpg-error

# 修复/dev/fd链接
ln -sf /proc/self/fd /dev/fd

# 强制重置密钥环
rm -rf /etc/pacman.d/gnupg/*
pacman-key --init
EOF

    # 导入密钥
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
curl -sL "https://archlinux.org/people/developers-keys/" | \
    grep -Eo '0x[0-9A-F]{16}' | \
    xargs sudo pacman-key --recv-keys

pacman-key --populate archlinux endeavouros
EOF
}

configure_system() {
    echo "=== 系统配置强化 ==="
    # 准备chroot环境
    mount --bind /dev "$MOUNT_DIR/dev"
    mount -t proc proc "$MOUNT_DIR/proc"
    mount -t sysfs sys "$MOUNT_DIR/sys"
    mount -t devpts devpts "$MOUNT_DIR/dev/pts"
    
    # DNS配置修复
    echo "nameserver 8.8.8.8" > "$MOUNT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$MOUNT_DIR/etc/resolv.conf"

    # 执行chroot配置
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
export LC_ALL=C

echo ">> 同步系统时间..."
timedatectl set-ntp true
hwclock --hctosys

echo ">> 修复软件仓库..."
pacman -Syy --noconfirm

echo ">> 安装关键组件..."
pacman -S --noconfirm --needed \
    base-devel curl wget reflector \
    gpgme libassuan libgpg-error

echo ">> 二次验证密钥..."
pacman-key --refresh-keys
pacman-key --list-sigs | grep -E 'ARCH|ENDEAVOUROS' || {
    echo "密钥验证失败！";
    exit 1;
}

echo ">> 重建软件仓库数据库..."
rm -rf /var/lib/pacman/sync/*
pacman -Syy --noconfirm

echo ">> 安装基础系统..."
pacman -S --noconfirm \
    linux linux-headers linux-firmware \
    grub efibootmgr networkmanager

echo ">> 配置GRUB..."
grub-install --target=i386-pc --recheck /dev/sda
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> 网络服务配置..."
systemctl enable NetworkManager.service
EOF

    # 最终验证
    echo "=== 最终验证 ==="
    chroot "$MOUNT_DIR" /bin/bash -c \
        "pacman -Q linux grub && ls /boot/grub/i386-pc/normal.mod" || {
        echo "关键组件验证失败！"
        exit 1
    }
}

main() { /* 保持不变 */ }

# 启动安装流程
main
