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

# ======================
# 初始化清理
# ======================
echo "===== 步骤 1/10：准备环境 ====="
cleanup() {
  echo "===== 清理挂载点 ====="
  umount -R /mnt/sfs_layers/* 2>/dev/null || true
  umount -l /mnt/iso 2>/dev/null || true
  umount -l /root/ntfs 2>/dev/null || true
  rm -rf /mnt/sfs_layers /mnt/manjaro.iso
}
trap cleanup EXIT

# ======================
# 磁盘空间检查函数
# ======================
check_disk_space() {
  local path=$1
  local min_gb=$2
  local available=$(df -B1G "$path" | awk 'NR==2 {print $4}' | tr -d 'G')
  
  [ "$available" -ge "$min_gb" ] || {
    echo "[-] 错误：$path 需要至少 ${min_gb}GB 可用空间（当前可用：${available}GB）"
    exit 1
  }
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
  #check_disk_space "/mnt" 5
  wget -c --show-progress -O /mnt/manjaro.iso "$MANJARO_ISO_URL" || exit 1
fi

echo "===== 步骤 5/10：挂载ISO ====="
mkdir -p /mnt/iso
mount -o loop /mnt/manjaro.iso /mnt/iso || exit 1

echo "===== 步骤 6/10：准备系统分区 ====="
echo "[!] 即将格式化：$TARGET_PARTITION"
read -rp "确认继续？[y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

#check_disk_space "$TARGET_PARTITION" 20
mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION" || exit 1
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || exit 1

echo "===== 步骤 7/10：合并系统层 ====="
SFS_LAYERS=(
  "/mnt/iso/manjaro/x86_64/rootfs.sfs"    # 基础层 (最低优先级)
  "/mnt/iso/manjaro/x86_64/desktopfs.sfs" # 桌面层
  "/mnt/iso/manjaro/x86_64/mhwdfs.sfs"    # 驱动层 (最高优先级)
)

mkdir -p /mnt/sfs_layers
for idx in "${!SFS_LAYERS[@]}"; do
  layer_file="${SFS_LAYERS[$idx]}"
  layer_dir="/mnt/sfs_layers/layer$idx"
  
  # 挂载SFS文件
  mkdir -p "$layer_dir"
  echo "[+] 挂载第 $((idx+1)) 层: $(basename "$layer_file")"
  mount -t squashfs -o loop,ro "$layer_file" "$layer_dir" || exit 1

  # 复制文件（高优先级覆盖低优先级）
  echo "  |- 正在合并文件..."
  cp -a --backup=numbered "$layer_dir"/* "$MOUNT_DIR/" 2>&1 | \
    awk '{print "    |  "$0}'
  echo "  |- 已合并文件数: $(find "$layer_dir" | wc -l)"
done

echo "===== 步骤 8/10：系统基础配置 ====="
echo "[+] 生成fstab..."
root_uuid=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$root_uuid / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

echo "===== 步骤 9/10：安装引导程序 ====="
mount --bind /dev  "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys  "$MOUNT_DIR/sys"
chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck "$TARGET_DISK"
chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg

echo "===== 步骤 10/10：安装完成 ====="
echo -e "\n\e[32m[√] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo -e "运行以下命令重启：\n  umount -R $MOUNT_DIR && reboot"
