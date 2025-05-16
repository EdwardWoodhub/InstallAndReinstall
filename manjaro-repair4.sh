#!/bin/bash
set -e

# ======================
# 配置参数（安装前必填）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录
ISO_PATH="/root/ntfs/iso/manjaro.iso" # ISO存放路径
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化环境
# ======================
cleanup() {
  echo "===== 清理挂载点 ====="
  umount -l /root/iso 2>/dev/null || true
  umount -l /root/ntfs 2>/dev/null || true
  umount -R "$MOUNT_DIR" 2>/dev/null || true
  rm -rf /root/sfs_layers
}
trap cleanup EXIT

# ======================
# 安装SquashFS工具（适配Debian）
# ======================
install_squashfs_tools() {
  echo "===== 安装SquashFS工具 ====="
  if ! command -v unsquashfs &>/dev/null; then
    echo "[+] 安装squashfs-tools..."
    apt-get update -qq
    apt-get install -y squashfs-tools || {
      echo "[-] 安装失败，请检查网络或软件源"
      exit 1
    }
  else
    echo "[+] squashfs-tools 已安装"
  fi
}

# ======================
# 主安装流程（优化磁盘占用）
# ======================
echo "===== 步骤1/10：检查权限 ====="
[ "$(id -u)" != "0" ] && { echo "[-] 需要root权限"; exit 1; }

install_squashfs_tools

echo "===== 步骤2/10：智能挂载NTFS分区 ====="
mkdir -p /root/ntfs
if [ -f "$ISO_PATH" ]; then
  echo "[+] 以只读模式挂载NTFS分区"
  ntfsfix "$NTFS_PARTITION" || exit 1
  mount -t ntfs-3g -o ro "$NTFS_PARTITION" /root/ntfs || exit 1
else
  echo "[!] 以读写模式挂载NTFS分区（用于下载ISO）"
  ntfsfix "$NTFS_PARTITION" || exit 1
  mount -t ntfs-3g -o rw "$NTFS_PARTITION" /root/ntfs || exit 1
fi

echo "===== 步骤3/10：处理ISO文件 ====="
if [ -f "$ISO_PATH" ]; then
  echo "[+] 使用现有ISO：$ISO_PATH"
else
  echo "[!] 开始下载ISO..."
  mkdir -p "$(dirname "$ISO_PATH")"
  wget -c --show-progress -O "$ISO_PATH.part" "$MANJARO_ISO_URL" || exit 1
  mv "$ISO_PATH.part" "$ISO_PATH"  # 原子操作确保文件完整性
fi

echo "===== 步骤4/10：挂载ISO ====="
mkdir -p /root/iso
mount -o loop "$ISO_PATH" /root/iso || {
  echo "[-] ISO挂载失败，请检查文件完整性"
  exit 1
}

echo "===== 步骤5/10：准备系统分区 ====="
echo "[!] 即将格式化：$TARGET_PARTITION"
read -rp "确认继续？[y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION" || exit 1
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || exit 1

echo "===== 步骤6/10：优化合并SFS文件 ====="
SFS_LAYERS=(
  "/root/iso/manjaro/x86_64/rootfs.sfs"    # 基础层
  "/root/iso/manjaro/x86_64/desktopfs.sfs" # 桌面层
  "/root/iso/manjaro/x86_64/mhwdfs.sfs"    # 驱动层（最高优先级）
)

# 使用内存盘减少磁盘写入（需要至少2GB空闲内存）
RAMDISK="/root/sfs_layers"
mkdir -p "$RAMDISK"
mount -t tmpfs -o size=2G tmpfs "$RAMDISK" || {
  echo "[!] 内存盘挂载失败，改用磁盘存储"
  RAMDISK="/root/sfs_layers"
  mkdir -p "$RAMDISK"
}

for idx in "${!SFS_LAYERS[@]}"; do
  sfs_file="${SFS_LAYERS[$idx]}"
  layer_dir="$RAMDISK/layer$idx"
  
  # 直接挂载SFS避免解压（减少磁盘占用）
  echo "[+] 挂载层 $((idx+1)): $(basename "$sfs_file")"
  mkdir -p "$layer_dir"
  mount -t squashfs -o loop,ro "$sfs_file" "$layer_dir" || exit 1

  # 使用rsync增量同步（避免重复写入）
  echo "  |- 增量同步文件..."
  rsync -aHAX --delete --progress "$layer_dir/" "$MOUNT_DIR/" 2>&1 | \
    awk '/^sent/ {print "    |  传输量：" $2 "  速度：" $7}'
done

echo "===== 步骤7/10：生成fstab ====="
root_uuid=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$root_uuid / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

echo "===== 步骤8/10：安装引导程序 ====="
mount --bind /dev  "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys  "$MOUNT_DIR/sys"

chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck "$TARGET_DISK" || exit 1
chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg || exit 1

echo "===== 步骤9/10：清理临时文件 ====="
umount -R "$RAMDISK"/* 2>/dev/null || true
umount -l "$RAMDISK" 2>/dev/null || true

echo "===== 步骤10/10：安装完成 ====="
echo -e "\n\e[32m[√] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo -e "重启命令：\n  umount -R $MOUNT_DIR && reboot"
