#!/bin/bash
set -e

# 配置参数
TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"
NTFS_PARTITION="/dev/sda2"
MOUNT_POINT="/root/windisk"
ISO_DIR="$MOUNT_POINT/iso"
POP_OS_ISO_URL="https://iso.pop-os.org/22.04/amd64/intel/13/pop-os_22.04_amd64_intel_13.iso"

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "错误：必须使用 root 运行！" >&2
  exit 1
fi

# 安装工具
echo "安装依赖..."
apt update && apt install -y ntfs-3g squashfs-tools

ntfsfix  "$NTFS_PARTITION"

# 挂载 NTFS 分区到 /root/windisk
echo "挂载 NTFS 分区..."
umount "$NTFS_PARTITION" 2>/dev/null || true
ntfsfix  "$NTFS_PARTITION"
mkdir -p "$MOUNT_POINT" 

mount -t ntfs-3g -o rw,remove_hiberfile "$NTFS_PARTITION" "$MOUNT_POINT"
mkdir -p "$ISO_DIR"
# 下载 ISO
echo "下载 ISO..."
wget -q --show-progress -O "$ISO_DIR/pop-os.iso" "$POP_OS_ISO_URL"

# 检查 ISO
if [ ! -f "$ISO_DIR/pop-os.iso" ]; then
  echo "错误：ISO 下载失败！"
  exit 1
fi

# 格式化系统分区
echo "格式化 $TARGET_PARTITION..."
umount "$TARGET_PARTITION" 2>/dev/null || true
mkfs.ext4 -F -L POP_OS "$TARGET_PARTITION"

# 挂载系统分区到 /mnt
mount "$TARGET_PARTITION" /mnt

# 挂载 ISO 并解压文件
echo "处理 ISO..."
mkdir -p /mnt/iso
mount -o loop "$ISO_DIR/pop-os.iso" /mnt/iso
SQUASHFS_PATH=$(find /mnt/iso -name "filesystem.squashfs" | head -n 1)
mkdir -p /tmp/squashfs
mount -t squashfs -o loop "$SQUASHFS_PATH" /tmp/squashfs
cp -a /tmp/squashfs/* /mnt/
umount /tmp/squashfs
umount /mnt/iso

# 挂载虚拟文件系统（为 update-grub 准备）
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# 安装 GRUB 到 MBR（关键修改）
echo "安装 GRUB..."
grub-install \
  --target=i386-pc \
  --root-directory=/mnt \
  --recheck \
  --force \
  "$TARGET_DISK"

# 生成 GRUB 配置（仍需 chroot）
echo "生成 GRUB 配置..."
chroot /mnt /bin/bash -c "update-grub"

# 生成 fstab
echo "生成 /etc/fstab..."
ROOT_UUID=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$ROOT_UUID / ext4 defaults 0 1" > /mnt/etc/fstab

# 清理
umount -R /mnt
umount "$MOUNT_POINT"

# 重启
echo "重启系统..."
reboot
