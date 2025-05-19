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

check_network() {
    echo "=== 网络连接检查 ==="
    local test_host="mirror.alpix.eu"
    
    hwclock --hctosys
    
    if ! nslookup $test_host >/dev/null 2>&1; then
        echo "DNS解析失败，配置备用DNS..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        
        if ! nslookup $test_host >/dev/null 2>&1; then
            echo "错误：DNS解析失败，请检查："
            echo "1. 防火墙设置是否允许DNS查询（UDP 53）"
            echo "2. 是否处于需要认证的网络环境（如酒店WiFi）"
            echo "3. 企业网络是否限制访问外部DNS"
            exit 1
        fi
    fi
    
    if ! curl -sI https://$test_host >/dev/null; then
        echo "HTTP连接测试失败，请检查："
        echo "1. 防火墙是否允许HTTPS（TCP 443）"
        echo "2. 是否配置了代理（export http_proxy=...）"
        echo "3. 系统时间是否准确（当前时间：$(date))"
        exit 1
    fi
    
    echo "网络连接验证通过"
}

check_dependencies() {
    echo "=== 检查依赖项 ==="
    local required=(
        "mount" "lsblk" "fsck" "ntfsfix" 
        "genfstab" "modprobe" "cp" "ping"
        "curl" "gzip" "nslookup"
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

prepare_environment() {
    echo "=== 初始化环境 ==="
    for module in loop squashfs fuse; do
        if ! modprobe "$module" 2>/dev/null; then
            echo "警告：无法加载内核模块 $module"
        fi
    done
}

mount_ntfs() {
    echo "=== 处理NTFS分区 ==="
    mkdir -p "$NTFS_MOUNT"
    
    echo "正在修复NTFS文件系统..."
    ntfsfix -d "$NTFS_PARTITION"

    if ! mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT"; then
        echo "错误：NTFS分区挂载失败"
        exit 1
    fi
}

download_iso() {
    echo "=== 下载ISO文件 ==="
    local tmp_dir="/tmp/iso.download"
    mkdir -p "$tmp_dir"
    
    for i in {1..3}; do
        if curl -L -k -C - -o "$tmp_dir/iso.tmp" "$ISO_URL" \
            --connect-timeout 30 \
            --retry 3 \
            --retry-delay 10 \
            --retry-all-errors; then
            break
        else
            echo "下载失败，10秒后重试 ($i/3)..."
            sleep 10
        fi
    done || {
        echo "错误：ISO下载失败"
        exit 1
    }
    
    mkdir -p "$(dirname "$ISO_PATH")"
    mv "$tmp_dir/iso.tmp" "$ISO_PATH"
    echo "ISO下载完成: $ISO_PATH"
}

mount_ext4() {
    echo "=== 处理EXT4分区 ==="
    mkdir -p "$MOUNT_DIR"
    
    umount "$MOUNT_DIR" 2>/dev/null || {
        echo "警告：存在残留挂载，尝试强制卸载..."
        umount -l "$MOUNT_DIR" || true
    }

    echo "执行深度文件系统检查..."
    if ! fsck -y -f -C 0 "$EXT4_PARTITION"; then
        echo "错误：文件系统修复失败，尝试备份superblock..."
        local backup_sb=$(mkfs.ext4 -n "$EXT4_PARTITION" 2>/dev/null | awk '/Backup superblock/{print $NF}')
        [ -z "$backup_sb" ] && backup_sb=32768
        fsck -y -b $backup_sb "$EXT4_PARTITION" || {
            echo "致命错误：无法修复文件系统"
            exit 1
        }
    fi

    echo "挂载分区..."
    for i in {1..3}; do
        if mount -o rw,nodelalloc,strictatime,data=ordered "$EXT4_PARTITION" "$MOUNT_DIR"; then
            if touch "$MOUNT_DIR/.rw_test"; then
                rm -f "$MOUNT_DIR/.rw_test"
                echo "挂载验证成功"
                return 0
            fi
            echo "写入测试失败，尝试重新挂载 ($i/3)..."
            umount "$MOUNT_DIR"
        fi
        sleep 1
    done

    echo "致命错误：无法以读写模式挂载分区"
    echo "调试信息："
    lsblk -o NAME,FSTYPE,STATE,MOUNTPOINT,RO "$EXT4_PARTITION"
    dmesg | grep -i -A10 "$EXT4_PARTITION"
    exit 1
}

extract_system() {
    echo "=== 解压系统文件 ==="
    local temp_squashfs="/mnt/squashfs_temp"
    mkdir -p "$temp_squashfs" "/mnt/iso"

    if ! mount -o loop,ro "$ISO_PATH" "/mnt/iso"; then
        echo "错误：无法挂载ISO文件"
        exit 1
    fi
    
    local sfs_path="/mnt/iso/arch/x86_64/airootfs.sfs"
    [ -f "$sfs_path" ] || {
        echo "错误：找不到airootfs.sfs"
        exit 1
    }

    if ! mount -t squashfs -o ro "$sfs_path" "$temp_squashfs"; then
        echo "错误：无法挂载squashfs文件"
        exit 1
    fi

    echo "正在复制系统文件..."
    cp -a "$temp_squashfs/"* "$MOUNT_DIR/"

    umount "$temp_squashfs"
    umount "/mnt/iso"
}

configure_mirrors() {
    echo "=== 配置欧洲镜像源 ==="
    cat > "$MOUNT_DIR/etc/pacman.d/mirrorlist" <<'EOL'
## 德国（主镜像）
Server = https://mirror.archlinux.de/archlinux/$repo/os/$arch
## 法国（备用镜像1）
Server = https://archlinux.mirrors.ovh.net/archlinux/$repo/os/$arch
## 荷兰（备用镜像2）
Server = https://ftp.nluug.nl/os/Linux/distr/archlinux/$repo/os/$arch
## EndeavourOS官方镜像（IP直连）
Server = https://94.16.105.229/endeavouros/repo/$repo/$arch
EOL
}

initialize_keyring() {
    echo "=== 初始化密钥环 ==="
    mkdir -p "$MOUNT_DIR/etc/pacman.d/gnupg"
    echo "keyserver hkp://keys.openpgp.org" > "$MOUNT_DIR/etc/pacman.d/gnupg/gpg.conf"
    
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
rm -rf /etc/pacman.d/gnupg/*
pacman-key --init
pacman-key --populate archlinux
EOF
}

configure_system() {
    echo "=== 系统配置 ==="
    if ! touch "$MOUNT_DIR/etc/.config_test"; then
        echo "致命错误：文件系统仍为只读状态"
        mount | grep "$MOUNT_DIR"
        lsblk -o NAME,MOUNTPOINT,FSTYPE,STATE,RO "$EXT4_PARTITION"
        exit 1
    fi
    rm -f "$MOUNT_DIR/etc/.config_test"

    mkdir -p "$MOUNT_DIR/etc"
    cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"

    genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"
    
    mount --bind /dev "$MOUNT_DIR/dev"
    mount -t devpts devpts "$MOUNT_DIR/dev/pts"
    mount --bind /proc "$MOUNT_DIR/proc"
    mount --bind /sys "$MOUNT_DIR/sys"
    
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
export LC_ALL=C

echo ">> 更新系统时间..."
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc --utc

echo ">> 更新软件数据库（带重试）..."
MIRRORS=(
    "https://mirror.archlinux.de/archlinux/\$repo/os/\$arch"
    "https://archlinux.mirrors.ovh.net/archlinux/\$repo/os/\$arch"
    "https://ftp.nluug.nl/os/Linux/distr/archlinux/\$repo/os/\$arch"
    "https://94.16.105.229/endeavouros/repo/\$repo/\$arch"
)

for i in {1..5}; do
    if pacman -Syy --disable-download-timeout; then
        break
    else
        echo "数据库同步失败，切换镜像源 ($i/5)..."
        selected_mirror=${MIRRORS[$(( (i-1) % ${#MIRRORS[@]} ))]}
        echo "使用镜像：$selected_mirror"
        echo "Server = $selected_mirror" > /etc/pacman.d/mirrorlist
        sleep 5
    fi
done || {
    echo "错误：无法同步数据库"
    exit 1
}

echo ">> 安装基本系统（分组件重试）..."
packages=(
    base linux linux-headers linux-firmware 
    grub openssh sudo ntp ca-certificates
)

for pkg in "${packages[@]}"; do
    for i in {1..3}; do
        if pacman -S --noconfirm --needed "$pkg"; then
            break
        else
            echo "安装 $pkg 失败，更换镜像源 ($i/3)..."
            next_mirror=${MIRRORS[$(( (i-1) % ${#MIRRORS[@]} ))]}
            echo "Server = $next_mirror" > /etc/pacman.d/mirrorlist
            pacman -Syy
        fi
    done || {
        echo "致命错误：无法安装 $pkg"
        exit 1
    }
done

echo ">> 配置本地化..."
sed -i 's/#en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

echo ">> 设置root密码..."
until passwd; do
    echo "密码设置失败，请重试..."
done

echo ">> 安装引导程序..."
TARGET_DISK=$(lsblk -no pkname $(mount | grep ' / ' | awk '{print $1}'))
echo "检测到目标磁盘：/dev/$TARGET_DISK"
grub-install --target=i386-pc --recheck --debug "/dev/$TARGET_DISK"
find /boot/grub -type f | grep normal.mod || { echo "GRUB模块缺失！"; exit 1; }

echo ">> 生成GRUB配置..."
grub-mkconfig -o /boot/grub/grub.cfg
grep -i 'linux\|initrd' /boot/grub/grub.cfg || { echo "GRUB配置错误！"; exit 1; }

echo ">> 网络时间协议配置..."
systemctl enable systemd-timesyncd.service

echo ">> 最终验证："
echo "[时区验证]"
ls -l /etc/localtime | grep Europe/London
echo "[时间状态]"
timedatectl status
echo "[镜像连通性]"
curl -I https://mirror.alpix.eu/endeavouros/repo/core.db
EOF

    if [ ! -f "$MOUNT_DIR/boot/grub/i386-pc/normal.mod" ]; then
        echo "致命错误：GRUB模块未正确安装！"
        ls -lR "$MOUNT_DIR/boot"
        exit 1
    fi
}

main() {
    echo "======= EndeavourOS 欧洲镜像安装程序 ======="
    echo "启动时间: $(date +'%Y-%m-%d %H:%M:%S %Z')"
    check_network
    check_dependencies
    prepare_environment
    
    mount_ntfs
    
    if [ ! -f "$ISO_PATH" ]; then
        echo "未找到ISO文件，开始下载..."
        umount "$NTFS_MOUNT"
        if mount -t ntfs-3g -o rw "$NTFS_PARTITION" "$NTFS_MOUNT"; then
            download_iso
            umount "$NTFS_MOUNT"
            mount_ntfs
        else
            echo "错误：无法以读写模式挂载NTFS"
            exit 1
        fi
    fi
    
    mount_ext4
    extract_system
    configure_mirrors
    initialize_keyring
    configure_system
    
    echo "=== 安装完成 ==="
    echo "系统信息:"
    chroot "$MOUNT_DIR" cat /etc/os-release
    echo -e "\n首次启动后操作建议："
    echo "1. 检查时间同步：timedatectl status"
    echo "2. 更新系统：pacman -Syu"
    echo "3. 创建用户：useradd -m -G wheel 用户名"
    echo "4. 设置用户密码：passwd 用户名"
    echo "5. 重启系统：reboot"
}

# 启动安装流程
main
