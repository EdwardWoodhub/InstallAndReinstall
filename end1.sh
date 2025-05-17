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
    echo "执行清理操作..."
    for mountpoint in $MOUNT_DIR/dev/pts $MOUNT_DIR/dev $MOUNT_DIR/proc $MOUNT_DIR/sys $MOUNT_DIR $NTFS_MOUNT /mnt/iso; do
        umount -l $mountpoint 2>/dev/null || true
    done
    rm -rf /tmp/squashfs-*
}

prepare_environment() {
    echo "=== 环境准备 ==="
    modprobe loop || { echo "警告：无法加载loop模块"; }
    modprobe squashfs || { echo "警告：无法加载squashfs模块"; }
    modprobe fuse || { echo "警告：无法加载fuse模块"; }
    
    echo "安装必要工具..."
    pacman -Sy --noconfirm curl gzip xz tar gcc make 2>/dev/null || {
        echo "尝试最小化安装..."
        curl -O https://geo.mirror.pkgbuild.com/core/os/x86_64/curl-8.7.1-1-x86_64.pkg.tar.zst
        pacman -U --noconfirm *.pkg.tar.zst
    }
}

install_static_unsquashfs() {
    echo "=== 安装静态编译版unsquashfs ==="
    local TMP_DIR="/tmp/squashfs-static"
    mkdir -p $TMP_DIR

    echo "尝试从可靠源下载静态二进制..."
    if ! curl -L -o $TMP_DIR/unsquashfs.gz \
        "https://cdn.statically.io/gh/endeavouros-team/static-binaries/main/unsquashfs/unsquashfs-4.6.1.gz" \
        --connect-timeout 30; then
        echo "主镜像下载失败，尝试备用源..."
        curl -L -o $TMP_DIR/unsquashfs.gz \
            "https://raw.fastgit.org/endeavouros-team/static-binaries/main/unsquashfs/unsquashfs-4.6.1.gz"
    fi

    echo "验证并安装二进制..."
    if file $TMP_DIR/unsquashfs.gz | grep -q "gzip compressed"; then
        gzip -d $TMP_DIR/unsquashfs.gz
        mv $TMP_DIR/unsquashfs /usr/local/bin/
        chmod +x /usr/local/bin/unsquashfs
    else
        echo "下载文件损坏，转为源码编译"
        build_squashfs_from_source
        return
    fi

    if ! /usr/local/bin/unsquashfs -version | grep -q "4.6.1"; then
        echo "二进制验证失败，重新编译..."
        build_squashfs_from_source
    fi
}

build_squashfs_from_source() {
    echo "=== 从源码编译squashfs-tools ==="
    local SRC_DIR="/tmp/squashfs-src"
    mkdir -p $SRC_DIR

    echo "尝试从多个镜像下载源码..."
    local MIRRORS=(
        "https://github.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz"
        "https://ghproxy.com/https://github.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz"
        "https://hub.yzuu.cf/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz"
        "https://kgithub.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz"
    )

    for mirror in "${MIRRORS[@]}"; do
        echo "正在尝试镜像源：$mirror"
        if curl -L -o $SRC_DIR/squashfs.tar.gz "$mirror" \
            --connect-timeout 20 \
            --retry 3 \
            --retry-delay 5; then
            if tar -tzf $SRC_DIR/squashfs.tar.gz >/dev/null 2>&1; then
                echo "下载验证成功"
                break
            else
                echo "文件损坏，尝试下一个镜像"
                rm -f $SRC_DIR/squashfs.tar.gz
            fi
        else
            echo "下载失败，尝试下一个镜像"
            continue
        fi
    done

    if [ ! -f $SRC_DIR/squashfs.tar.gz ]; then
        echo "错误：所有镜像源均不可用！"
        exit 1
    fi

    echo "解压源码..."
    tar -xzf $SRC_DIR/squashfs.tar.gz -C $SRC_DIR

    echo "编译静态版本..."
    cd $SRC_DIR/squashfs-tools-4.6.1/squashfs-tools
    CFLAGS="-static -std=gnu90" make -j$(nproc) || {
        echo "标准编译失败，尝试兼容模式..."
        sed -i 's/-Werror//' Makefile
        CFLAGS="-static -std=gnu90" make -j$(nproc)
    }
    strip unsquashfs
    cp unsquashfs /usr/local/bin/
}

download_iso() {
    echo "=== 下载ISO文件 ==="
    mkdir -p "$(dirname "$ISO_PATH")"
    echo "使用镜像源：$ISO_URL"

    for i in {1..3}; do
        if curl -L -o "$ISO_PATH.part" -C - "$ISO_URL" --connect-timeout 60; then
            mv "$ISO_PATH.part" "$ISO_PATH"
            return 0
        else
            echo "下载中断，10秒后重试（第$i次）..."
            sleep 10
        fi
    done
    echo "错误：ISO下载失败！"
    exit 1
}

mount_filesystems() {
    echo "=== 挂载文件系统 ==="
    [ -b "$NTFS_PARTITION" ] || { echo "错误：NTFS分区不存在"; exit 1; }
    [ -b "$EXT4_PARTITION" ] || { echo "错误：EXT4分区不存在"; exit 1; }
    
    echo "处理NTFS分区..."
    mkdir -p $NTFS_MOUNT
    if ! mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT" 2>/dev/null; then
        echo "尝试修复NTFS..."
        ntfsfix -d "$NTFS_PARTITION"
        if ! mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT"; then
            echo "紧急模式：只读挂载NTFS"
            mount -t ntfs -o ro,force "$NTFS_PARTITION" "$NTFS_MOUNT" || {
                echo "致命错误：无法挂载NTFS分区"
                exit 1
            }
        fi
    fi

    echo "检查ISO文件..."
    if [ ! -f "$ISO_PATH" ]; then
        echo "需要下载ISO文件..."
        umount "$NTFS_MOUNT"
        mount -t ntfs-3g -o rw "$NTFS_PARTITION" "$NTFS_MOUNT"
        download_iso
        umount "$NTFS_MOUNT"
        mount -t ntfs-3g -o ro "$NTFS_PARTITION" "$NTFS_MOUNT"
    fi

    echo "准备系统分区..."
    mkdir -p $MOUNT_DIR
    fsck -y "$EXT4_PARTITION" || true
    if ! mount "$EXT4_PARTITION" "$MOUNT_DIR"; then
        echo "尝试修复EXT4文件系统..."
        fsck -y -f "$EXT4_PARTITION"
        mount "$EXT4_PARTITION" "$MOUNT_DIR" || {
            echo "无法挂载EXT4分区"
            exit 1
        }
    fi
}

extract_system() {
    echo "=== 解压系统文件 ==="
    if ! command -v unsquashfs &>/dev/null; then
        install_static_unsquashfs
    fi

    echo "挂载ISO镜像..."
    mkdir -p /mnt/iso
    mount -o loop,ro "$ISO_PATH" /mnt/iso

    local SFS_PATH="/mnt/iso/arch/x86_64/airootfs.sfs"
    [ -f "$SFS_PATH" ] || { echo "错误：找不到airootfs.sfs"; exit 1; }

    echo "解压系统文件..."
    if ! unsquashfs -f -d "$MOUNT_DIR" "$SFS_PATH"; then
        echo "解压失败，尝试直接挂载..."
        modprobe squashfs
        mount -t squashfs "$SFS_PATH" "$MOUNT_DIR" || {
            echo "致命错误：无法挂载squashfs"
            exit 1
        }
    fi
}

configure_system() {
    echo "=== 系统配置 ==="
    echo "生成fstab..."
    mkdir -p "$MOUNT_DIR/etc"
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
pacman-key --populate archlinux endeavouros

echo "配置镜像源..."
cat > /etc/pacman.d/mirrorlist <<MIRROR
Server = https://mirrors.bfsu.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
MIRROR
pacman -Syy --noconfirm

echo "安装基础系统..."
pacman -S --noconfirm base linux linux-firmware grub openssh sudo

echo "配置本地化..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "设置root密码："
until passwd; do
    echo "密码设置失败，请重试..."
done

echo "生成initramfs..."
mkinitcpio -P

echo "安装引导程序..."
DISK_DEVICE="$(lsblk -no pkname "$EXT4_PARTITION")"
grub-install --target=i386-pc "/dev/$DISK_DEVICE"
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
    echo "当前时间：$(date)"
    echo "系统信息：$(uname -a)"
    prepare_environment
    mount_filesystems
    extract_system
    configure_system

    echo "=== 安装完成！ ==="
    read -p "是否立即重启？(y/N) " -n 1 -r
    [[ $REPLY =~ ^[Yy]$ ]] && reboot || echo "执行 exit 退出chroot后请手动重启"
}

# 执行主程序
main
