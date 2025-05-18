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
    
    if ! ping -c 2 -W 3 $test_host &>/dev/null; then
        echo "配置备用DNS..."
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        
        if ! ping -c 2 -W 3 $test_host &>/dev/null; then
            echo "错误：无法连接到欧洲镜像"
            echo "请检查："
            echo "1. 防火墙设置"
            echo "2. 网络电缆/无线连接"
            echo "3. 代理配置"
            exit 1
        fi
    fi
    echo "网络连接验证通过"
}

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
        echo "检测到缺失命令: ${missing[*]}"
        
        # 动态修复reflector缺失
        if [[ " ${missing[*]} " == *"reflector"* ]]; then
            echo ">>> 正在自动安装reflector..."
            
            # 配置临时镜像源
            echo "Server = https://mirror.archlinux.de/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
            echo "Server = https://ftp.nluug.nl/os/Linux/distr/archlinux/\$repo/os/\$arch" >> /etc/pacman.d/mirrorlist
            
            # 修复密钥环
            echo "初始化密钥环..."
            pacman-key --init
            pacman-key --populate archlinux
            
            # 强制更新数据库
            echo "同步软件数据库..."
            pacman -Sy --noconfirm archlinux-keyring
            
            # 安装reflector
            if ! pacman -S --noconfirm reflector; then
                echo ">>> 尝试备用安装方案..."
                curl -LO https://geo.mirror.pkgbuild.com/extra/os/x86_64/reflector-2023-9-any.pkg.tar.zst
                pacman -U --noconfirm reflector-*.pkg.tar.zst
                rm -f reflector-*.pkg.tar.zst
            fi
            
            # 二次验证
            if command -v reflector &>/dev/null; then
                echo "reflector 安装成功"
                missing=("${missing[@]/reflector}")
            else
                echo "错误：无法自动安装reflector"
                exit 1
            fi
        fi
        
        # 检查剩余缺失项
        if [ ${#missing[@]} -gt 0 ]; then
            echo "错误：仍需手动安装 - ${missing[*]}"
            exit 1
        fi
    fi
    echo "所有依赖项已满足"
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
    
    # 先执行ntfsfix修复
    echo "正在修复NTFS文件系统..."
    ntfsfix -d "$NTFS_PARTITION"

    # 挂载分区
    if ! mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT"; then
        echo "错误：NTFS分区挂载失败"
        exit 1
    fi
}

download_iso() {
    echo "=== 下载ISO文件 ==="
    local tmp_dir="/tmp/iso.download"
    mkdir -p "$tmp_dir"
    
    # 带重试机制的下载
    for i in {1..3}; do
        if curl -L -k -C - -o "$tmp_dir/iso.tmp" "$ISO_URL" \
            --connect-timeout 30 \
            --retry 3 \
            --retry-delay 10; then
            break
        else
            echo "下载失败，10秒后重试 ($i/3)..."
            sleep 10
        fi
    done || {
        echo "错误：ISO下载失败"
        exit 1
    }
    
    # 移动文件
    mkdir -p "$(dirname "$ISO_PATH")"
    mv "$tmp_dir/iso.tmp" "$ISO_PATH"
    echo "ISO下载完成: $ISO_PATH"
}

mount_ext4() {
    echo "=== 处理EXT4分区 ==="
    mkdir -p "$MOUNT_DIR"
    
    # 强制卸载可能存在的残留挂载
    umount "$MOUNT_DIR" 2>/dev/null || {
        echo "警告：存在残留挂载，尝试强制卸载..."
        umount -l "$MOUNT_DIR" || true
    }

    # 深度文件系统修复
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

    # 挂载分区（强制读写模式）
    echo "挂载分区..."
    for i in {1..3}; do
        if mount -o rw,nodelalloc,strictatime,data=ordered "$EXT4_PARTITION" "$MOUNT_DIR"; then
            # 写入验证
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

    # 挂载ISO
    if ! mount -o loop,ro "$ISO_PATH" "/mnt/iso"; then
        echo "错误：无法挂载ISO文件"
        exit 1
    fi
    
    # 定位squashfs文件
    local sfs_path="/mnt/iso/arch/x86_64/airootfs.sfs"
    [ -f "$sfs_path" ] || {
        echo "错误：找不到airootfs.sfs"
        exit 1
    }

    # 挂载squashfs到临时目录
    if ! mount -t squashfs -o ro "$sfs_path" "$temp_squashfs"; then
        echo "错误：无法挂载squashfs文件"
        exit 1
    fi

    # 复制文件到系统目录（保持权限）
    echo "正在复制系统文件..."
    cp -a "$temp_squashfs/"* "$MOUNT_DIR/"

    # 清理临时挂载
    umount "$temp_squashfs"
    umount "/mnt/iso"
}

configure_mirrors() {
    echo "=== 生成优化镜像源 ==="
    reflector \
        --verbose \
        --country France,Germany,Netherlands,Sweden \
        --protocol https \
        --latest 30 \
        --sort rate \
        --save "$MOUNT_DIR/etc/pacman.d/mirrorlist"
    
    # 添加EndeavourOS专用源
    cat >> "$MOUNT_DIR/etc/pacman.d/mirrorlist" <<'EOL'
## EndeavourOS 欧洲源
Server = https://mirror.alpix.eu/endeavouros/repo/$repo/$arch
EOL

    # 强制使用欧洲DNS
    mkdir -p "$MOUNT_DIR/etc"
    echo "nameserver 8.8.8.8" > "$MOUNT_DIR/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$MOUNT_DIR/etc/resolv.conf"
}

initialize_keyring() {
    echo "=== 强化密钥初始化 ==="
    # 安装必要依赖
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
pacman -Syy --noconfirm --needed \
    gnupg gpgme libassuan libgpg-error

# 修复/dev/fd符号链接
ln -sf /proc/self/fd /dev/fd

# 强制重置密钥环
rm -rf /etc/pacman.d/gnupg
mkdir -p /etc/pacman.d/gnupg
pacman-key --init

# 导入官方密钥
curl -sL "https://archlinux.org/people/developers-keys/" | \
    grep -Eo '0x[0-9A-F]{16}' | \
    xargs pacman-key --recv-keys

# 信任密钥
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
    
    # 执行chroot配置
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
export LC_ALL=C

echo ">> 同步硬件时钟..."
hwclock --hctosys --utc

echo ">> 更新软件仓库..."
pacman -Syy --noconfirm

echo ">> 安装核心组件..."
pacman -S --noconfirm --needed \
    base linux linux-headers linux-firmware \
    systemd glibc grub efibootmgr networkmanager

echo ">> 修复初始化系统链接..."
ln -sf /usr/lib/systemd/systemd /sbin/init
ln -sf /usr/lib/systemd/systemd /usr/lib/systemd/systemd-udevd

echo ">> 生成initramfs..."
mkinitcpio_conf="/etc/mkinitcpio.conf"
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block filesystems keyboard fsck)/' $mkinitcpio_conf
mkinitcpio -P

echo ">> 配置GRUB引导参数..."
ROOT_UUID=$(blkid -s UUID -o value $EXT4_PARTITION)
cat > /etc/default/grub <<GRUB_CFG
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="EndeavourOS"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
GRUB_CMDLINE_LINUX="init=/usr/lib/systemd/systemd root=UUID=$ROOT_UUID"
GRUB_PRELOAD_MODULES="part_gpt part_msdos"
GRUB_TERMINAL_INPUT=console
GRUB_TERMINAL_OUTPUT=console
GRUB_DISABLE_OS_PROBER=true
GRUB_GFXMODE=auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_SAVEDEFAULT=false
GRUB_CFG

echo ">> 安装GRUB引导..."
TARGET_DISK=$(lsblk -no pkname $(mount | awk '$3 == "/" {print $1}'))
grub-install --target=i386-pc --recheck --debug "/dev/$TARGET_DISK"
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> 启用网络服务..."
systemctl enable NetworkManager.service

echo ">> 最终验证..."
ls -l /usr/lib/systemd/systemd /sbin/init
lsinitcpio /boot/initramfs-linux.img | grep -q systemd || exit 1
EOF

    # 安装后验证
    echo "=== 安装后验证 ==="
    if [ ! -f "$MOUNT_DIR/boot/grub/i386-pc/normal.mod" ]; then
        echo "错误：GRUB模块缺失！"
        exit 1
    fi
    if ! chroot "$MOUNT_DIR" pacman -Q linux systemd grub; then
        echo "错误：核心组件未正确安装！"
        exit 1
    fi
}

main() {
    echo "======= EndeavourOS 欧洲镜像安装程序 ======="
    echo "启动时间: $(date +'%Y-%m-%d %H:%M:%S')"
    check_network
    check_dependencies
    prepare_environment
    
    # NTFS处理流程
    mount_ntfs
    
    # ISO检查与下载
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
    
    # EXT4处理流程
    mount_ext4
    extract_system
    configure_mirrors
    initialize_keyring
    configure_system
    
    echo "=== 安装完成 ==="
    echo "系统信息:"
    chroot "$MOUNT_DIR" cat /etc/os-release
    echo -e "\n请输入 reboot 重启系统"
}

# 启动安装流程
main
