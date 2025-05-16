#!/bin/bash
set -e

# 配置参数（根据实际情况调整）
TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"     # 系统分区（会被格式化！）
NTFS_PARTITION="/dev/sda2"       # NTFS 数据分区
SYS_MOUNT_POINT="/root/manjaro"  # 系统分区挂载点
NTFS_MOUNT_POINT="/root/ntfs"    # NTFS 分区挂载点
ISO_DIR="$NTFS_MOUNT_POINT/iso"  # ISO 存储目录
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "错误：必须使用 root 权限运行！" >&2
  exit 1
fi

# ========== 创建挂载点目录 ==========
mkdir -p {$SYS_MOUNT_POINT,$NTFS_MOUNT_POINT}

# ========== 挂载 NTFS 分区 ==========
echo "挂载 NTFS 分区..."
ntfsfix "$NTFS_PARTITION"
mount -t ntfs-3g -o rw,remove_hiberfile "$NTFS_PARTITION" "$NTFS_MOUNT_POINT"

# ========== 下载 ISO ==========
echo "下载 Manjaro ISO..."
mkdir -p "$ISO_DIR"
ISO_FILE="$ISO_DIR/manjaro.iso"
if [ -f "$ISO_File" ]; then
  echo "检测到已存在 ISO 文件: $ISO_File"
  echo "跳过下载步骤..."
else
  echo "开始下载 Manjaro ISO..."
  wget --show-progress -O "$ISO_File" "$MANJARO_ISO_URL"
fi

# ========== 挂载 ISO ==========
echo "处理 ISO 文件..."
ISO_MOUNT_DIR="$NTFS_MOUNT_POINT/iso_mount"
mkdir -p "$ISO_MOUNT_DIR"
mount -o loop "$ISO_FILE" "$ISO_MOUNT_DIR"

# ========== 合并文件系统 ==========
echo "合并系统层级..."
SQUASHFS_DIR="$ISO_MOUNT_DIR/manjaro/x86_64"
UNION_DIR="/tmp/unionfs"
mkdir -p "$UNION_DIR"/{upper,work}
chmod 755 "$UNION_DIR"/{upper,work}

mount -t overlay overlay -o \
lowerdir="$SQUASHFS_DIR/rootfs.sfs:$SQUASHFS_DIR/desktopfs.sfs:$SQUASHFS_DIR/mhwdfs.sfs",\
upperdir="$UNION_DIR/upper",\
workdir="$UNION_DIR/work" \
"$UNION_DIR"

# ========== 格式化系统分区 ==========
echo "格式化系统分区..."
umount "$TARGET_PARTITION" 2>/dev/null || true
mkfs.ext4 -F -L Manjaro "$TARGET_PARTITION"

# 挂载系统分区
mount "$TARGET_PARTITION" "$SYS_MOUNT_POINT"

# 复制文件到系统分区
echo "复制系统文件..."
rsync -aHAX --progress "$UNION_DIR/" "$SYS_MOUNT_POINT/"
cp -av "$ISO_MOUNT_DIR/boot" "$SYS_MOUNT_POINT/"

# ========== 配置引导 ==========
echo "配置引导..."
mount --bind /dev  "$SYS_MOUNT_POINT/dev"
mount --bind /proc "$SYS_MOUNT_POINT/proc"
mount --bind /sys  "$SYS_MOUNT_POINT/sys"
mount --bind /run  "$SYS_MOUNT_POINT/run"

# 生成 fstab
ROOT_UUID=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$ROOT_UUID / ext4 defaults 0 1" > "$SYS_MOUNT_POINT/etc/fstab"

# 安装 GRUB
chroot "$SYS_MOUNT_POINT" grub-install --target=i386-pc --recheck "$TARGET_DISK"
chroot "$SYS_MOUNT_POINT" grub-mkconfig -o /boot/grub/grub.cfg

# ========== 清理环境 ==========
echo "清理环境..."
{
  umount -l "$UNION_DIR"
  umount -R "$ISO_MOUNT_DIR"
  umount "$NTFS_MOUNT_POINT"
} 2>/dev/null

echo "安装完成！正在重启..."
reboot
