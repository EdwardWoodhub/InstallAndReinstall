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
# 初始化环境
# ======================
cleanup() {
  echo "===== 清理挂载点 ====="
  umount -l /root/iso 2>/dev/null || true
  umount -l /root/ntfs 2>/dev/null || true
  umount -R "$MOUNT_DIR" 2>/dev/null || true
  umount -R /root/aufs_union/* 2>/dev/null || true
  rm -rf /root/aufs_union
}
trap cleanup EXIT

# ======================
# 安装AUFS支持
# ======================
install_aufs_support() {
  echo "===== 安装AUFS支持 ====="
  if ! grep -q aufs /proc/filesystems; then
    echo "[+] 安装AUFS内核模块..."
    apt-get update -qq
    if ! apt-get install -y linux-image-extra-$(uname -r) aufs-tools; then
      echo "[-] AUFS安装失败，请检查内核兼容性"
      exit 1
    fi
    if ! modprobe aufs; then
      echo "[-] 无法加载AUFS内核模块"
      exit 1
    fi
  else
    echo "[+] AUFS已支持"
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/6：检查权限 ====="
[ "$(id -u)" != "0" ] && { echo "[-] 需要root权限"; exit 1; }

install_aufs_support

echo "===== 步骤2/6：挂载NTFS分区 ====="
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

echo "===== 步骤3/6：处理ISO文件 ====="
if [ -f "$ISO_PATH" ]; then
  echo "[+] 使用现有ISO：$ISO_PATH"
else
  echo "[!] 开始下载ISO..."
  mkdir -p "$(dirname "$ISO_PATH")"
  wget -c --show-progress -O "$ISO_PATH.part" "$MANJARO_ISO_URL" || exit 1
  mv "$ISO_PATH.part" "$ISO_PATH"
fi

echo "===== 步骤4/6：准备系统分区 ====="
echo "[!] 即将格式化：$TARGET_PARTITION"
read -rp "确认继续？[y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION" || exit 1
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || exit 1

echo "===== 步骤5/6：配置AUFS联合挂载 ====="
AUFS_BASE="/root/aufs_union"
SFS_LAYERS=(
  "/root/iso/manjaro/x86_64/rootfs.sfs"    # 基础层 (lowest priority)
  "/root/iso/manjaro/x86_64/desktopfs.sfs" # 中间层
  "/root/iso/manjaro/x86_64/mhwdfs.sfs"    # 驱动层 (highest priority)
)

# 创建挂载结构
mkdir -p "$AUFS_BASE"/{layers,union}
for idx in "${!SFS_LAYERS[@]}"; do
  layer_sfs="${SFS_LAYERS[$idx]}"
  layer_dir="$AUFS_BASE/layers/layer$idx"
  echo "[+] 挂载层 $((idx+1)): $(basename "$layer_sfs")"
  mkdir -p "$layer_dir"
  mount -t squashfs -o loop,ro "$layer_sfs" "$layer_dir" || exit 1
done

# 创建可写层（内存中）
RW_LAYER="/tmp/aufs_rw"
mkdir -p "$RW_LAYER"

# AUFS挂载参数（关键配置）：
# - br: 分支顺序（可写层最后挂载）
# - udba=reval: 提升性能
# - dio: 启用直接IO
mount -t aufs -o br="$RW_LAYER=rw:${SFS_LAYERS[@]/#//root/aufs_union/layers/layer}" \
               -o udba=reval,dio \
               none "$AUFS_BASE/union" || exit 1

echo "===== 步骤6/6：系统部署 ====="
echo "[+] 同步文件到系统分区..."
rsync -aHAX --ignore-errors --progress \
  --exclude='/usr/share/icons/Papirus/64x64/apps/appimagekit-*' \
  "$AUFS_BASE/union/" "$MOUNT_DIR/" || {
  echo "[!] 部分文件同步失败（已跳过只读文件）"
}

echo "[+] 清理冲突文件..."
find "$MOUNT_DIR" -name '*.svg' -type f -exec chattr -i {} \; -delete 2>/dev/null || true

echo "[+] 生成fstab..."
root_uuid=$(blkid -s UUID -o value "$TARGET_PARTITION")
echo "UUID=$root_uuid / ext4 defaults 0 1" > "$MOUNT_DIR/etc/fstab"

echo "[+] 安装引导程序..."
mount --bind /dev  "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys  "$MOUNT_DIR/sys"
chroot "$MOUNT_DIR" grub-install --target=i386-pc --recheck "$TARGET_DISK" || exit 1
chroot "$MOUNT_DIR" grub-mkconfig -o /boot/grub/grub.cfg || exit 1

echo -e "\n\e[32m[√] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo -e "重启命令：\n  umount -R $MOUNT_DIR && reboot"
