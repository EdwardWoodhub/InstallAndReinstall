#!/bin/bash
set -e

# ======================
# 配置参数（安装前必填）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（存放ISO）
MOUNT_DIR="/mnt/system"            # 系统挂载目录
ISO_PATH="/mnt/ntfs/iso/manjaro.iso"
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化环境
# ======================
cleanup() {
  echo "===== 清理挂载点 ====="
  umount -l /mnt/iso 2>/dev/null || true
  umount -l /mnt/ntfs 2>/dev/null || true
  umount -R "$MOUNT_DIR" 2>/dev/null || true
  rm -rf /mnt/sfs_layers /mnt/manjaro.iso
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
# 主安装流程
# ======================
echo "===== 步骤1/10：检查权限 ====="
[ "$(id -u)" != "0" ] && { echo "[-] 需要root权限"; exit 1; }

install_squashfs_tools

echo "===== 步骤2/10：挂载NTFS分区 ====="
mkdir -p /mnt/ntfs
ntfsfix "$NTFS_PARTITION" || exit 1
mount -t ntfs-3g -o ro "$NTFS_PARTITION" /mnt/ntfs || exit 1

echo "===== 步骤3/10：处理ISO文件 ====="
if [ -f "$ISO_PATH" ]; then
  echo "[+] 使用现有ISO：$ISO_PATH"
  cp -v "$ISO_PATH" /mnt/manjaro.iso
else
  echo "[!] 开始下载ISO..."
  wget -c --show-progress -O /mnt/manjaro.iso "$MANJARO_ISO_URL" || exit 1
fi

echo "===== 步骤4/10：挂载ISO ====="
mkdir -p /mnt/iso
mount -o loop /mnt/manjaro.iso /mnt/iso || exit 1

echo "===== 步骤5/10：准备系统分区 ====="
echo "[!] 即将格式化：$TARGET_PARTITION"
read -rp "确认继续？[y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION" || exit 1
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || exit 1

echo "===== 步骤6/10：解压合并SFS文件 ====="
SFS_LAYERS=(
  "/mnt/iso/manjaro/x86_64/rootfs.sfs"    # 基础层（最先解压）
  "/mnt/iso/manjaro/x86_64/desktopfs.sfs" # 桌面层
  "/mnt/iso/manjaro/x86_64/mhwdfs.sfs"    # 驱动层（最后解压，覆盖优先级最高）
)

mkdir -p /mnt/sfs_layers
for idx in "${!SFS_LAYERS[@]}"; do
  sfs_file="${SFS_LAYERS[$idx]}"
  layer_dir="/mnt/sfs_layers/layer$idx"
  
  # 解压SFS文件
  echo "[+] 解压层 $((idx+1)): $(basename "$sfs_file")"
  unsquashfs -f -d "$layer_dir" "$sfs_file" || exit 1

  # 合并文件（后解压的层覆盖先前的）
  echo "  |- 正在合并文件到系统分区..."
  cp -a --backup=numbered "$layer_dir"/* "$MOUNT_DIR/" 2>&1 | \
    awk '{print "    |  "$0}'
  echo "  |- 已合并文件数：$(find "$layer_dir" | wc -l)"
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
rm -rf /mnt/sfs_layers/*

echo "===== 步骤10/10：安装完成 ====="
echo -e "\n\e[32m[√] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo -e "重启命令：\n  umount -R $MOUNT_DIR && reboot"
