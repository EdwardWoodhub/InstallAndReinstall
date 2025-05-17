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
ISO_URL="https://mirrors.bfsu.edu.cn/endeavouros/iso/EndeavourOS_Mercury-Neo-2025.03.19.iso"
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
    )
    
    for mountpoint in "${mounts[@]}"; do
        if mountpoint -q "$mountpoint"; then
            echo "卸载 $mountpoint"
            umount -l "$mountpoint" 2>/dev/null || true
        fi
    done
    
    rm -rf "/tmp/iso.download"
    echo "清理完成"
}

check_dependencies() {
    echo "=== 检查依赖项 ==="
    local required=(
        "mount" "lsblk" "fsck" "ntfsfix" 
        "genfstab" "modprobe"
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
    
    # 检测下载工具
    local downloader=""
    for cmd in curl wget; do
        if command -v "$cmd" &>/dev/null; then
            downloader="$cmd"
            break
        fi
    done
    
    [ -z "$downloader" ] && {
        echo "错误：需要 curl/wget 来下载ISO"
        exit 1
    }

    # 下载函数
    case $downloader in
        curl)
            curl -L -k -C - -o "$tmp_dir/iso.tmp" "$ISO_URL" \
                --connect-timeout 30 \
                --retry 3 \
                --retry-delay 10
            ;;
        wget)
            wget -c -O "$tmp_dir/iso.tmp" "$ISO_URL" \
                --timeout=30 \
                --tries=3 \
                --waitretry=10
            ;;
    esac
    
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
    mkdir -p "/mnt/iso"
    
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
    
    # 解压系统
    if command -v unsquashfs &>/dev/null; then
        unsquashfs -f -d "$MOUNT_DIR" "$sfs_path"
    else
        mount -t squashfs "$sfs_path" "$MOUNT_DIR"
    fi
}

configure_system() {
    echo "=== 系统配置 ==="
    # 预检目录权限
    if ! touch "$MOUNT_DIR/etc/.write_test"; then
        echo "错误：无法写入系统目录"
        echo "当前挂载选项："
        mount | grep "$MOUNT_DIR"
        exit 1
    fi
    rm -f "$MOUNT_DIR/etc/.write_test"

    # 生成fstab
    mkdir -p "$MOUNT_DIR/etc"
    genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"
    
    # 准备chroot环境
    mount --bind /dev "$MOUNT_DIR/dev"
    mount --bind /proc "$MOUNT_DIR/proc"
    mount --bind /sys "$MOUNT_DIR/sys"
    
    # 执行chroot配置
    chroot "$MOUNT_DIR" /bin/bash <<'EOF'
#!/bin/bash
set -e
export LC_ALL=C

echo ">> 配置镜像源..."
cat > /etc/pacman.d/mirrorlist <<MIRROR
Server = https://mirrors.bfsu.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
MIRROR

echo ">> 初始化密钥环..."
pacman-key --init
pacman-key --populate archlinux

echo ">> 更新系统..."
pacman -Syy --noconfirm
pacman -S --noconfirm base linux linux-firmware grub

echo ">> 配置本地化..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo ">> 设置root密码..."
until passwd; do
    echo "密码设置失败，请重试..."
done

echo ">> 安装引导程序..."
grub-install --target=i386-pc "$(lsblk -no pkname $EXT4_PARTITION)"
grub-mkconfig -o /boot/grub/grub.cfg

echo ">> 启用SSH服务..."
systemctl enable sshd.service
EOF
}

main() {
    echo "======= EndeavourOS 安装程序 ======="
    echo "启动时间: $(date +'%F %T')"
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
    configure_system
    
    echo "=== 安装完成 ==="
    echo "系统信息:"
    chroot "$MOUNT_DIR" cat /etc/os-release
    echo -e "\n请输入 reboot 重启系统"
}

# 启动安装流程
main
