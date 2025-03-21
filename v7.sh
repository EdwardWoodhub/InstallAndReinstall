#!/bin/bash
set -e

# 配置参数
TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"    # 要安装系统的分区（会被格式化！）
NTFS_PARTITION="/dev/sda2"      # NTFS 数据分区的设备标识
MOUNT_POINT="/root/windisk"     # NTFS 分区的挂载点
ISO_DIR="$MOUNT_POINT/iso"      # ISO 存放目录
POP_OS_ISO_URL="https://iso.pop-os.org/22.04/amd64/intel/13/pop-os_22.04_amd64_intel_13.iso"

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "错误：必须使用 root 权限运行！" >&2
  exit 1
fi

# 安装必要工具
echo "安装依赖工具..."
apt update && apt install -y ntfs-3g squashfs-tools

# 创建挂载点目录
echo "创建挂载点目录..."
mkdir -p "$MOUNT_POINT" "$ISO_DIR"

ntfsfix  "$NTFS_PARTITION"            # 修复 NTFS 错误

# 挂载 NTFS 分区到 /root/windisk
echo "挂载 NTFS 分区 $NTFS_PARTITION 到 $MOUNT_POINT..."
umount "$NTFS_PARTITION" 2>/dev/null || true  # 强制卸载残留挂载

mount -t ntfs-3g -o rw,remove_hiberfile "$NTFS_PARTITION" "$MOUNT_POINT"

# 下载 ISO 到 /root/windisk/iso
echo "下载 Pop!_OS ISO 到 $ISO_DIR..."
wget -q --show-progress -O "$ISO_DIR/pop-os.iso" "$POP_OS_ISO_URL"

# 检查 ISO 文件
if [ ! -f "$ISO_DIR/pop-os.iso" ]; then
  echo "错误：ISO 下载失败！请检查网络连接。"
  exit 1
fi

# 格式化系统分区
echo "格式化系统分区 $TARGET_PARTITION..."
umount "$TARGET_PARTITION" 2>/dev/null || true
mkfs.ext4 -F -L POP_OS "$TARGET_PARTITION"

# 挂载系统分区到 /mnt
echo "挂载系统分区到 /mnt..."
mount "$TARGET_PARTITION" /mnt

# 挂载 ISO 并解压系统文件
echo "处理 ISO 文件..."
mkdir -p /mnt/iso
if mount -o loop "$ISO_DIR/pop-os.iso" /mnt/iso; then
  # 找到 SquashFS 文件路径
  SQUASHFS_PATH=$(find /mnt/iso -name "filesystem.squashfs" | head -n 1)
  if [ -z "$SQUASHFS_PATH" ]; then
    echo "错误：未找到 filesystem.squashfs！"
    exit 1
  fi

  # 挂载 SquashFS 并复制文件
  mkdir -p /tmp/squashfs
  if mount -t squashfs -o loop "$SQUASHFS_PATH" /tmp/squashfs; then
    cp -a /tmp/squashfs/* /mnt/
    umount /tmp/squashfs
  else
    echo "错误：无法挂载 SquashFS！"
    exit 1
  fi

  umount /mnt/iso
else
  echo "错误：无法挂载 ISO！"
  exit 1
fi

# 配置 Chroot 环境
echo "配置引导环境..."
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# 安装 GRUB 引导
chroot /mnt /bin/bash -c " \
  grub-install --target=i386-pc --recheck --force $TARGET_DISK && \
  update-grub"

# 生成 fstab
echo "生成 /etc/fstab..."
ROOT_UUID=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$ROOT_UUID / ext4 defaults 0 1" > /mnt/etc/fstab

# 清理环境
echo "清理操作..."
umount -R /mnt            # 卸载系统分区
umount "$MOUNT_POINT"     # 卸载 NTFS 分区
rm -rf /tmp/squashfs      # 删除临时目录

# 重启系统
echo "正在重启..."
reboot