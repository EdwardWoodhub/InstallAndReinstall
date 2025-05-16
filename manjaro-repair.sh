#!/bin/bash
set -e

# ======================
# 配置参数（安装前必填）
# ======================
TARGET_DISK="/dev/sda"             # 要安装系统的磁盘
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录
ISO_PATH="/root/ntfs/iso/manjaro.iso" # ISO存放路径
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化清理
# ======================
echo "===== 步骤 1/10：准备环境 ====="
rm -rf /mnt/sfs_layers
mkdir -p /mnt/sfs_layers/{root,desktop,mhwdf}
cleanup() {
  echo "===== 清理挂载点 ====="
  umount -l /mnt/iso 2>/dev/null || echo "[-] 卸载/mnt/iso失败"
  umount -R /mnt/sfs_layers 2>/dev/null || echo "[-] 卸载SFS层失败"
  umount -R "$MOUNT_DIR" 2>/dev/null || echo "[-] 卸载系统目录失败"
  umount -l /root/ntfs 2>/dev/null || echo "[-] 卸载NTFS分区失败"
}
trap cleanup EXIT

# ======================
# 权限检查
# ======================
echo "===== 步骤 2/10：检查权限 ====="
if [ "$(id -u)" != "0" ]; then
  echo "[-] 错误：必须使用root权限运行！"
  exit 1
fi

# ======================
# 内核模块检查
# ======================
echo "===== 步骤 3/10：检查SquashFS支持 ====="
if ! grep -q squashfs /proc/filesystems; then
  echo "[!] 加载squashfs内核模块..."
  if ! modprobe squashfs; then
    echo "[-] 无法加载squashfs模块，请检查内核配置"
    exit 1
  fi
fi

# ======================
# 挂载NTFS分区检查ISO
# ======================
echo "===== 步骤 4/10：检查ISO缓存 ====="
mkdir -p /root/ntfs
ntfsfix "$NTFS_PARTITION" || {
  echo "[-] NTFS分区修复失败：$NTFS_PARTITION"
  exit 1
}
mount -t ntfs-3g -o ro "$NTFS_PARTITION" /root/ntfs || {
  echo "[-] NTFS分区挂载失败"
  exit 1
}

if [ -f "$ISO_PATH" ]; then
  echo "[+] 找到ISO缓存：$ISO_PATH"
  cp -v "$ISO_PATH" /mnt/manjaro.iso
else
  echo "[!] 未找到ISO，开始下载..."
  wget --show-progress -O /mnt/manjaro.iso "$MANJARO_ISO_URL" || {
    echo "[-] ISO下载失败"
    exit 1
  }
  echo "[+] 下载完成，备份ISO到NTFS分区..."
  mkdir -p /root/ntfs/iso
  cp -v /mnt/manjaro.iso "$ISO_PATH"
fi

# ======================
# 挂载ISO
# ======================
echo "===== 步骤 5/10：挂载ISO ====="
mkdir -p /mnt/iso
mount -o loop /mnt/manjaro.iso /mnt/iso || {
  echo "[-] ISO挂载失败"
  exit 1
}

# ======================
# 准备系统分区
# ======================
echo "===== 步骤 6/10：准备系统分区 ====="
echo "[!] 即将格式化分区：$TARGET_PARTITION"
read -rp "确认继续？[y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
  echo "[-] 用户取消操作"
  exit 0
fi

mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION" || {
  echo "[-] 分区格式化失败"
  exit 1
}

mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || {
  echo "[-] 分区挂载失败"
  exit 1
}

# ======================
# 合并系统层
# ======================
echo "===== 步骤 7/10：合并系统层 ====="

# 定义要处理的SFS文件列表（按优先级从低到高）
declare -A SFS_LAYERS=(
  ["base"]="/mnt/iso/manjaro/x86_64/rootfs.sfs"
  ["desktop"]="/mnt/iso/manjaro/x86_64/desktopfs.sfs" 
  ["drivers"]="/mnt/iso/manjaro/x86_64/mhwdfs.sfs"
)

# 分步处理每个层
for layer in base desktop drivers; do
  echo "[+] 处理 $layer 层..."
  sfs_path="${SFS_LAYERS[$layer]}"
  mount_point="/mnt/sfs_layers/$layer"
  
  # 创建挂载点
  mkdir -p "$mount_point"
  
  # 挂载SFS文件
  if ! mount -t squashfs -o loop,ro "$sfs_path" "$mount_point"; then
    echo "[-] 无法挂载：$sfs_path"
    exit 1
  fi
  
  # 复制文件（保留属性）
  echo "  |- 复制文件到系统分区..."
  cp -a --backup=numbered "$mount_point"/* "$MOUNT_DIR/" 2>&1 | \
    awk '{print "  |  "$0}'
  
  # 记录覆盖情况
  echo "  |- 已处理文件数：$(find "$mount_point" | wc -l)"
done

# ======================
# 系统配置
# ======================
echo "===== 步骤 8/10：系统基础配置 ====="
echo "[+] 挂载虚拟文件系统..."
mount --bind /dev  "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys  "$MOUNT_DIR/sys"
mount --bind /run  "$MOUNT_DIR/run"

echo "[+] 生成fstab..."
root_uuid=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$root_uuid / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

# ======================
# 安装引导
# ======================
echo "===== 步骤 9/10：安装引导程序 ====="
if ! chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck "$TARGET_DISK"; then
  echo "[-] GRUB安装失败"
  exit 1
fi

if ! chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg; then
  echo "[-] GRUB配置生成失败"
  exit 1
fi

# ======================
# 完成提示
# ======================
echo "===== 步骤 10/10：安装完成 ====="
echo -e "\n\e[32m[√] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo -e "请手动执行以下操作："
echo "1. 卸载分区：umount -R $MOUNT_DIR"
echo "2. 重启系统：reboot"
echo -e "\n警告：重启前请保存所有工作！"
