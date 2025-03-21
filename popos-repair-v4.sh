#!/bin/bash
set -e

# 配置参数
TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"
NTFS_PARTITION="/dev/sda2"
MOUNT_POINT="/mnt/ntfs"
ISO_DIR="$MOUNT_POINT/iso"
POP_OS_ISO_URL="https://iso.pop-os.org/22.04/amd64/intel/13/pop-os_22.04_amd64_intel_13.iso"

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "错误：必须使用 root 运行！" >&2
  exit 1
fi

# 安装依赖工具
echo "安装必要工具..."
apt update && apt install -y ntfs-3g squashfs-tools libarchive-tools

# 挂载 NTFS 分区
echo "挂载 NTFS 数据分区..."
umount $NTFS_PARTITION 2>/dev/null || true
ntfsfix --force $NTFS_PARTITION
mkdir -p $MOUNT_POINT
mount -t ntfs-3g -o rw,remove_hiberfile $NTFS_PARTITION $MOUNT_POINT
mkdir -p $ISO_DIR

# 下载 ISO
echo "下载 Pop!_OS ISO 到 $ISO_DIR..."
cd $ISO_DIR
wget -q --show-progress -O pop-os.iso "$POP_OS_ISO_URL"

# 检查文件是否存在
if [ ! -f "pop-os.iso" ]; then
  echo "错误：ISO 下载失败！请检查网络连接。"
  exit 1
fi

# 格式化系统分区
echo "格式化系统分区 $TARGET_PARTITION..."
umount $TARGET_PARTITION 2>/dev/null || true
mkfs.ext4 -F -L POP_OS $TARGET_PARTITION

# 挂载系统分区
echo "挂载系统分区..."
mount $TARGET_PARTITION /mnt

# 方法1：直接解压 ISO 内容（无需挂载）
echo "解压 ISO 并部署系统文件..."
mkdir -p /tmp/iso_extract
bsdtar -xvf $ISO_DIR/pop-os.iso -C /tmp/iso_extract
unsquashfs -f -d /mnt /tmp/iso_extract/casper/filesystem.squashfs
rm -rf /tmp/iso_extract

# 配置 Chroot 环境
echo "配置引导程序..."
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# 安装 GRUB
chroot /mnt /bin/bash -c " \
  grub-install --target=i386-pc --recheck --force $TARGET_DISK && \
  update-grub"

# 生成 fstab
echo "生成 /etc/fstab..."
ROOT_UUID=$(blkid -s UUID -o value $TARGET_PARTITION)
echo "UUID=$ROOT_UUID / ext4 defaults 0 1" > /mnt/etc/fstab

# 清理环境
echo "卸载文件系统..."
umount -R /mnt
umount $MOUNT_POINT

# 重启
echo "正在重启系统..."
reboot