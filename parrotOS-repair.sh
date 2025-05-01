#!/bin/bash
set -e

# 配置参数（根据实际情况调整）
TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"     # 要安装系统的分区（会被格式化！）
NTFS_PARTITION="/dev/sda2"       # NTFS 数据分区设备标识
MOUNT_POINT="/root/windisk"      # NTFS 分区挂载点
ISO_DIR="$MOUNT_POINT/iso"       # ISO 存储目录
PARROT_ISO_URL="https://deb.parrot.sh/parrot/iso/6.3.2/Parrot-home-6.3.2_amd64.iso"  # 替换有效链接

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "错误：必须使用 root 权限运行！" >&2
  exit 1
fi

# 安装工具
echo "安装依赖..."
apt update && apt install -y ntfs-3g squashfs-tools

# 修复 NTFS 分区错误
ntfsfix  "$NTFS_PARTITION"

# ========== NTFS 分区处理 ==========
echo "处理 NTFS 数据分区..."
# 卸载可能存在的残留挂载
umount "$NTFS_PARTITION" 2>/dev/null || true

# 修复 NTFS 分区错误
ntfsfix  "$NTFS_PARTITION"

# 创建挂载点目录
mkdir -p "$MOUNT_POINT"
mkdir -p "$ISO_DIR"

# 挂载 NTFS 分区（读写模式）
mount -t ntfs-3g -o rw,remove_hiberfile "$NTFS_PARTITION" "$MOUNT_POINT"

# ========== 下载 ISO 到 NTFS 分区 ==========
echo "下载 ISO 到数据分区..."
wget -q --show-progress -O "$ISO_DIR/parrot.iso" "$PARROT_ISO_URL"

# 检查文件完整性
if [ ! -f "$ISO_DIR/parrot.iso" ]; then
  echo "错误：ISO 下载失败！"
  exit 1
fi

# ========== 系统分区处理 ==========
echo "格式化系统分区 $TARGET_PARTITION..."
umount "$TARGET_PARTITION" 2>/dev/null || true
mkfs.ext4 -F -L ParrotOS "$TARGET_PARTITION"

# 挂载系统分区到 /mnt
MOUNT_SYS="/mnt/parrot"
mkdir -p "$MOUNT_SYS"
mount "$TARGET_PARTITION" "$MOUNT_SYS"

# ========== 从 NTFS 分区加载 ISO ==========
echo "从数据分区挂载 ISO..."
mkdir -p /mnt/iso
mount -o loop "$ISO_DIR/parrot.iso" /mnt/iso

# 查找并解压系统文件
SQUASHFS_PATH=$(find /mnt/iso -name "filesystem.squashfs" | head -n 1)
if [ -z "$SQUASHFS_PATH" ]; then
  echo "错误：未找到系统镜像文件！"
  exit 1
fi

echo "解压系统镜像到目标分区..."
mkdir -p /tmp/squashfs
mount -t squashfs -o loop "$SQUASHFS_PATH" /tmp/squashfs
cp -a /tmp/squashfs/* "$MOUNT_SYS"
umount /tmp/squashfs
umount /mnt/iso

# 验证关键文件
if [ ! -f "$MOUNT_SYS/boot/vmlinuz" ]; then
  echo "错误：内核文件缺失！"
  exit 1
fi

# ========== 引导配置 ==========
# 挂载虚拟文件系统
mount --bind /dev  "$MOUNT_SYS/dev"
mount --bind /proc "$MOUNT_SYS/proc"
mount --bind /sys  "$MOUNT_SYS/sys"

# 安装 GRUB（适配 BIOS 引导）
echo "安装 GRUB..."
chroot "$MOUNT_SYS" /bin/bash -c " \
  grub-install --target=i386-pc --recheck --force $TARGET_DISK && \
  update-grub"

# 生成 fstab
echo "生成 /etc/fstab..."
ROOT_UUID=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$ROOT_UUID / ext4 defaults 0 1" >  "$MOUNT_SYS/etc/fstab"

# ========== 清理操作 ==========
echo "卸载所有挂载点..."
# umount /mnt/iso
umount -R "$MOUNT_SYS"
umount "$MOUNT_POINT"

# 重启系统
echo "安装完成！正在重启..."
reboot
