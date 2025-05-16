#!/bin/bash
set -e

# ======================
# 配置参数（安装前必填）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录
ISO_PATH="/root/ntfs/iso/manjaro.iso" 
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"
OVERLAY_WORKDIR="/mnt/overlay_work" # OverlayFS工作目录

# ======================
# 初始化清理
# ======================
echo "===== 步骤 1/10：准备环境 ====="
cleanup() {
  echo "===== 清理挂载点 ====="
  umount -l "$OVERLAY_WORKDIR"/merged 2>/dev/null || true
  umount -R "$OVERLAY_WORKDIR"/lower/* 2>/dev/null || true
  umount -l /mnt/iso 2>/dev/null || true
  umount -l /root/ntfs 2>/dev/null || true
  rm -rf "$OVERLAY_WORKDIR" /mnt/manjaro.iso
}
trap cleanup EXIT

# ======================
# 磁盘空间检查函数
# ======================
check_disk_space() {
  local path=$1
  local min_gb=$2
  local available=$(df -B1G "$path" | awk 'NR==2 {print $4}' | tr -d 'G')
  
  if [ "$available" -lt "$min_gb" ]; then
    echo "[-] 错误：$path 需要至少 ${min_gb}GB 可用空间（当前可用：${available}GB）"
    exit 1
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤 2/10：检查权限 ====="
[ "$(id -u)" != "0" ] && { echo "[-] 需要root权限"; exit 1; }

echo "===== 步骤 3/10：检查NTFS分区 ====="
mkdir -p /root/ntfs
ntfsfix "$NTFS_PARTITION" || exit 1
mount -t ntfs-3g -o ro "$NTFS_PARTITION" /root/ntfs || exit 1

echo "===== 步骤 4/10：处理ISO文件 ====="
if [ -f "$ISO_PATH" ]; then
  echo "[+] 使用现有ISO：$ISO_PATH"
  ln -sf "$ISO_PATH" /mnt/manjaro.iso
else
  echo "[!] 开始下载ISO..."
  check_disk_space "/mnt" 5  # 至少需要5GB空间
  wget -c --show-progress -O /mnt/manjaro.iso "$MANJARO_ISO_URL" || exit 1
fi

echo "===== 步骤 5/10：挂载ISO ====="
mkdir -p /mnt/iso
mount -o loop /mnt/manjaro.iso /mnt/iso || exit 1

echo "===== 步骤 6/10：准备系统分区 ====="
echo "[!] 即将格式化：$TARGET_PARTITION"
read -rp "确认继续？[y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

check_disk_space "$TARGET_PARTITION" 20  # 系统分区至少20GB
mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION" || exit 1
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || exit 1

echo "===== 步骤 7/10：配置OverlayFS ====="
mkdir -p "$OVERLAY_WORKDIR"/{lower,upper,work,merged}
sfs_files=(
  "/mnt/iso/manjaro/x86_64/rootfs.sfs"    # 基础层
  "/mnt/iso/manjaro/x86_64/desktopfs.sfs" # 桌面层
  "/mnt/iso/manjaro/x86_64/mhwdfs.sfs"    # 驱动层（最高优先级）
)

for idx in "${!sfs_files[@]}"; do
  layer_dir="$OVERLAY_WORKDIR/lower/layer$idx"
  mkdir -p "$layer_dir"
  echo "[+] 挂载层 $((idx+1)): ${sfs_files[idx]##*/}"
  mount -t squashfs -o loop,ro "${sfs_files[idx]}" "$layer_dir" || exit 1
done

echo "===== 步骤 8/10：创建联合视图 ====="
lower_dirs=$(find "$OVERLAY_WORKDIR/lower" -mindepth 1 -maxdepth 1 -type d | sort | tr '\n' ':')
mount -t overlay overlay \
  -o lowerdir="${lower_dirs%:}",upperdir="$OVERLAY_WORKDIR/upper",workdir="$OVERLAY_WORKDIR/work" \
  "$OVERLAY_WORKDIR/merged" || exit 1

echo "===== 步骤 9/10：同步到系统分区 ====="
check_disk_space "$MOUNT_DIR" 15  # 检查目标分区空间
rsync -aHAX --progress "$OVERLAY_WORKDIR/merged/" "$MOUNT_DIR/" || exit 1

echo "===== 步骤 10/10：系统配置 ====="
echo "[+] 生成fstab..."
root_uuid=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$root_uuid / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

echo "[+] 安装GRUB..."
mount --bind /dev  "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys  "$MOUNT_DIR/sys"
chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck "$TARGET_DISK"
chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg

echo -e "\n\e[32m[√] 安装成功！耗时: ${SECONDS}秒\e[0m"
echo -e "运行以下命令重启：\n  umount -R $MOUNT_DIR && reboot"
