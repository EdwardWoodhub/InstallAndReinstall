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
ARCH_KEY="DDB867B92AA789C165EEFA799B729B06A40C17EA"
EOS_KEY="7D42C7F45FCFBFF7"
# ================================================

# ================= 全局函数 =================
cleanup() {
    echo "=== 执行清理操作 ==="
    local mounts=(
        "$MOUNT_DIR/dev/pts" 
        "$MOUNT_DIR/dev" 
        "$MOUNT_DIR/proc" 
        "$MOUNT_DIR/sys" 
        "$MOUNT_DIR" 
        "$NTFS_MOUNT" 
        "/mnt/iso"
        "/mnt/squashfs_temp"
    )
    
    for mountpoint in "${mounts[@]}"; do
        if mountpoint -q "$mountpoint"; then
            echo "卸载 $mountpoint"
            umount -l "$mountpoint" 2>/dev/null || true
        fi
    done
    
    rm -rf "/tmp/iso.download" "/mnt/squashfs_temp"
    echo "清理完成"
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

retry_command() {
    local cmd=$1
    local max_retries=${2:-3}
    local delay=${3:-10}
    local retries=0

    while true; do
        if eval "$cmd"; then
            return 0
        else
            ((retries++))
            if [ $retries -ge $max_retries ]; then
                return 1
            fi
            log "操作失败，${delay}秒后重试 (${retries}/${max_retries})"
            sleep $delay
        fi
    done
}

# ================= 核心功能 =================
init_system() {
    log "=== 初始化系统环境 ==="
    
    # 强制同步硬件时钟
    log "同步硬件时钟..."
    hwclock --hctosys --utc
    
    # 配置应急DNS
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    
    # 加载内核模块
    for module in loop squashfs fuse; do
        modprobe $module || log "警告：无法加载 $module 模块"
    done
}

fix_trustdb() {
    log "=== 修复信任数据库 ==="
    
    # 重置密钥环
    rm -rf /etc/pacman.d/gnupg/*
    pacman-key --init
    
    # 导入关键密钥
    import_key() {
        local key=$1
        log "导入密钥 $key"
        retry_command "pacman-key --recv-keys $key" 3 5
        pacman-key --lsign-key $key
    }
    
    import_key $ARCH_KEY
    import_key $EOS_KEY
    
    # 更新密钥数据库
    pacman-key --refresh-keys
    pacman -Sy --noconfirm archlinux-keyring
}

config_mirrors() {
    log "=== 配置镜像源 ==="
    
    # 安装reflector
    if ! command -v reflector &>/dev/null; then
        log "安装reflector..."
        pacman -Sy --noconfirm reflector
    fi
    
    # 生成优化镜像源
    reflector \
        --country France,Germany,Netherlands,Sweden \
        --protocol https \
        --latest 30 \
        --sort rate \
        --save /etc/pacman.d/mirrorlist
    
    # 添加EndeavourOS源
    cat >> /etc/pacman.d/mirrorlist <<EOL
## EndeavourOS 欧洲源
Server = https://mirror.alpix.eu/endeavouros/repo/\$repo/\$arch
EOL

    # 验证镜像源
    if ! curl -I https://mirror.archlinux.de &>/dev/null; then
        log "错误：镜像源不可达"
        exit 1
    fi
}

mount_partitions() {
    log "=== 处理存储分区 ==="
    
    # NTFS分区处理
    mkdir -p $NTFS_MOUNT
    ntfsfix -d $NTFS_PARTITION
    mount -t ntfs-3g -o ro $NTFS_PARTITION $NTFS_MOUNT
    
    # EXT4分区处理
    mkdir -p $MOUNT_DIR
    fsck -y -f $EXT4_PARTITION
    mount -o rw,nodelalloc $EXT4_PARTITION $MOUNT_DIR
}

deploy_system() {
    log "=== 部署操作系统 ==="
    
    # 挂载ISO
    mkdir -p /mnt/iso
    mount -o loop,ro $ISO_PATH /mnt/iso
    
    # 解压squashfs
    mkdir -p /mnt/squashfs
    mount -t squashfs /mnt/iso/arch/x86_64/airootfs.sfs /mnt/squashfs
    cp -a /mnt/squashfs/* $MOUNT_DIR
    
    # 准备chroot环境
    mount --bind /dev $MOUNT_DIR/dev
    mount -t proc proc $MOUNT_DIR/proc
    mount -t sysfs sys $MOUNT_DIR/sys
}

config_system() {
    log "=== 系统配置 ==="
    
    # 生成fstab
    genfstab -U $MOUNT_DIR > $MOUNT_DIR/etc/fstab
    
    chroot $MOUNT_DIR /bin/bash <<EOL
#!/bin/bash
set -e

# 基础配置
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# 内核安装
pacman -Syy --noconfirm
pacman -S --noconfirm linux linux-headers linux-firmware

# 引导配置
grub-install --target=i386-pc --recheck $(lsblk -no pkname $EXT4_PARTITION)
grub-mkconfig -o /boot/grub/grub.cfg

# 网络配置
systemctl enable NetworkManager
echo "EndeavourOS" > /etc/hostname
EOL
}

# ================= 主流程 =================
main() {
    [ $EUID -ne 0 ] && echo "必须使用root权限运行" && exit 1
    
    init_system
    fix_trustdb
    config_mirrors
    mount_partitions
    deploy_system
    config_system
    
    log "=== 安装完成 ==="
    log "重启前请检查："
    log "1. 查看引导配置: chroot ${MOUNT_DIR} grep -i 'linux' /boot/grub/grub.cfg"
    log "2. 验证网络配置: chroot ${MOUNT_DIR} ip a"
    log "3. 检查系统服务: chroot ${MOUNT_DIR} systemctl list-unit-files"
}

main
