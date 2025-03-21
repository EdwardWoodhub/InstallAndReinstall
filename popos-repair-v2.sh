#!/bin/bash
set -e

# 配置参数
TARGET_DISK="/dev/sda"
TARGET_PARTITION="/dev/sda1"
NTFS_PARTITION="/dev/sda2"      # NTFS 数据分区
ISO_DIR="/mnt/ntfs/iso"         # ISO 保存目录
POP_OS_ISO_URL="https://iso.pop-os.org/22.04/amd64/intel/13/pop-os_22.04_amd64_intel_13.iso"

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
  echo "错误：必须使用 root 运行！" >&2
  exit 1
fi

# 安装 NTFS 工具（关键修复）
echo "安装 NTFS-3G 工具..."
apt update && apt install -y ntfs-3g || {
  echo "安装 ntfs-3g 失败！请检查网络连接。"
  exit 1
}

# 修复 NTFS 分区写保护
echo "修复 NTFS 分区错误并解除写保护..."
ntfsfix  $NTFS_PARTITION

# 挂载 NTFS 分区（强制读写）
echo "挂载 NTFS 分区..."
umount $NTFS_PARTITION 2>/dev/null || true  # 强制卸载残留挂载
mkdir -p /mnt/ntfs
mount -t ntfs-3g -o rw,remove_hiberfile,uid=0,gid=0,dmask=022,fmask=133 $NTFS_PARTITION /mnt/ntfs || {
  echo "挂载 NTFS 分区失败！请检查设备标识或手动修复。"
  exit 1
}
mkdir -p $ISO_DIR

# 下载 ISO 到 NTFS 分区
echo "下载 Pop!_OS ISO 到第二分区..."
wget -q --show-progress -O $ISO_DIR/pop-os.iso "$POP_OS_ISO_URL"

# 格式化第一分区
echo "格式化系统分区..."
umount $TARGET_PARTITION 2>/dev/null || true
mkfs.ext4 -F -L POP_OS $TARGET_PARTITION

# 挂载系统分区
echo "挂载系统分区..."
mount $TARGET_PARTITION /mnt

# 从 NTFS 分区挂载 ISO 并解压
echo "从第二分区加载 ISO..."
mount -o loop $ISO_DIR/pop-os.iso /mnt/iso
unsquashfs -f -d /mnt /mnt/iso/casper/filesystem.squashfs

# 配置 Chroot 环境
echo "配置引导..."
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

# 清理卸载
echo "清理环境..."
umount /mnt/iso      # 卸载 ISO
umount -R /mnt       # 卸载系统分区
umount /mnt/ntfs     # 卸载 NTFS 分区（保留镜像不删除）

# 自动重启（仅适用于支持 CLI 重启的 VPS）
echo "尝试重启系统..."
reboot