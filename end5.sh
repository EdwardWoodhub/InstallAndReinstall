#!/bin/bash
set -euo pipefail
trap 'cleanup' EXIT

# ================= 用户配置区域 =================
NTFS_PARTITION="/dev/sda2"
EXT4_PARTITION="/dev/sda1"
MOUNT_DIR="/root/system"
NTFS_MOUNT="/root/ntfs"
ISO_NAME="endeavouros.iso"
ISO_PATH="$NTFS_MOUNT/iso/$ISO_NAME"
ISO_URL="https://mirror.alpix.eu/endeavouros/iso/EndeavourOS_Mercury-Neo-2025.03.19.iso"
ARCH_KEY="DDB867B92AA789C165EEFA799B729B06A40C17EA"  # Arch 主密钥
EOS_KEY="7D42C7F45FCFBFF7"                          # EndeavourOS 主密钥
# ================================================

# ================= 全局配置 =================
declare -A KEY_SERVERS=(
    ["default"]="hkp://keyserver.ubuntu.com:80"
    ["backup1"]="hkp://pgp.mit.edu:11371"
    ["backup2"]="hkp://keys.gnupg.net:11371"
    ["backup3"]="hkp://keyring.debian.org:11371"
)
KEY_FALLBACK_URL="https://keyserver.archlinux.org/pks/lookup?op=get&search="
LOG_FILE="/var/log/install_$(date +%Y%m%d%H%M).log"

# ================= 日志函数 =================
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ================= 清理函数 =================
cleanup() {
    log "=== 清理环境..."
    umount_partitions
    rm -rf "/tmp/keys" 2>/dev/null
}

# ================= 辅助函数 =================
umount_partitions() {
    local mounts=("$MOUNT_DIR" "$NTFS_MOUNT" "/mnt/iso")
    for mnt in "${mounts[@]}"; do
        if mountpoint -q "$mnt"; then
            umount -l "$mnt" 2>/dev/null && log "已卸载 $mnt"
        fi
    done
}

retry() {
    local cmd=$1
    local max_retries=${2:-3}
    local delay=${3:-10}
    local attempt=0

    while true; do
        if eval "$cmd"; then
            return 0
        else
            ((attempt++))
            if [ $attempt -ge $max_retries ]; then
                log "命令失败: $cmd (尝试 $max_retries 次)"
                return 1
            fi
            log "重试中 ($attempt/$max_retries)..."
            sleep $delay
        fi
    done
}

# ================= 密钥管理 =================
import_key() {
    local key_id=$1
    local key_name=$2
    local success=false

    log "正在导入 $key_name 密钥 ($key_id)"

    # 方案1: 尝试多个密钥服务器
    for server in "${!KEY_SERVERS[@]}"; do
        log "尝试从 ${KEY_SERVERS[$server]} 获取密钥"
        if retry "pacman-key --keyserver '${KEY_SERVERS[$server]}' --recv-keys '$key_id'" 3 5; then
            pacman-key --lsign-key "$key_id" && {
                success=true
                break
            }
        fi
    done

    # 方案2: 通过HTTP直接下载
    if ! $success; then
        log "尝试通过HTTP下载密钥..."
        mkdir -p /tmp/keys
        if curl -sL "${KEY_FALLBACK_URL}0x${key_id}" -o "/tmp/keys/${key_id}.asc"; then
            pacman-key --add "/tmp/keys/${key_id}.asc" && \
            pacman-key --lsign-key "$key_id" && success=true
        fi
    fi

    # 方案3: 使用预置密钥环
    if ! $success; then
        log "使用预置密钥文件..."
        if [ -f "/usr/share/pacman/keyrings/archlinux.gpg" ]; then
            pacman-key --add /usr/share/pacman/keyrings/archlinux.gpg && \
            pacman-key --lsign-key "$key_id" && success=true
        fi
    fi

    $success || {
        log "错误：无法导入 $key_name 密钥"
        exit 1
    }
}

# ================= 主流程 =================
init_system() {
    log "=== 初始化系统 ==="
    timedatectl set-ntp true
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    modprobe loop squashfs fuse
}

prepare_partitions() {
    log "=== 准备分区 ==="
    mkdir -p "$NTFS_MOUNT" "$MOUNT_DIR"
    
    # 处理NTFS分区
    ntfsfix -d "$NTFS_PARTITION"
    mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT"
    
    # 处理EXT4分区
    fsck -y -f "$EXT4_PARTITION"
    mount -o rw,nodelalloc "$EXT4_PARTITION" "$MOUNT_DIR"
}

deploy_system() {
    log "=== 部署系统 ==="
    mkdir -p /mnt/iso
    mount -o loop,ro "$ISO_PATH" /mnt/iso
    mount -t squashfs /mnt/iso/arch/x86_64/airootfs.sfs /mnt/squashfs
    
    log "复制系统文件..."
    rsync -aHAX --info=progress2 /mnt/squashfs/ "$MOUNT_DIR/"
    
    # 准备chroot环境
    mount --bind /dev "$MOUNT_DIR/dev"
    mount -t proc proc "$MOUNT_DIR/proc"
    mount -t sysfs sys "$MOUNT_DIR/sys"
}

config_system() {
    log "=== 系统配置 ==="
    genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"
    
    chroot "$MOUNT_DIR" /bin/bash <<EOL
set -e
export LC_ALL=C

# 密钥管理
echo "Server = https://mirror.archlinux.de/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
echo "Server = https://mirror.alpix.eu/endeavouros/repo/\$repo/\$arch" >> /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm archlinux-keyring endeavouros-keyring

# 基础配置
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# 引导配置
pacman -S --noconfirm grub linux linux-headers
grub-install --target=i386-pc --recheck $(lsblk -no pkname "$EXT4_PARTITION")
grub-mkconfig -o /boot/grub/grub.cfg

# 网络配置
systemctl enable NetworkManager
echo "EndeavourOS" > /etc/hostname
EOL
}

main() {
    [ $EUID -ne 0 ] && { log "必须使用root权限运行"; exit 1; }
    init_system
    import_key "$ARCH_KEY" "Arch Linux"
    import_key "$EOS_KEY" "EndeavourOS"
    prepare_partitions
    deploy_system
    config_system
    log "=== 安装成功！请重启系统 ==="
}

main
