#!/bin/bash
set -eo pipefail

# ======================
# 配置参数（安装前必填）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录（修改为/root目录）
ISO_PATH="/root/ntfs/iso/manjaro.iso" # ISO路径（修改为/root目录）
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化环境
# ======================
cleanup() {
  echo "===== 清理挂载点 ====="
  # 修改所有挂载点路径到/root
  for mnt in /root/{ntfs,iso,union,system}; do
    umount -l $mnt 2>/dev/null || true
  done
  rm -rf /root/{ntfs,iso,union,system} /tmp/unionfs*
}
trap cleanup EXIT

# ======================
# 安装必需工具
# ======================
install_deps() {
  echo "===== 安装依赖工具 ====="
  apt-get update -qq
  apt-get install -y squashfs-tools unionfs-fuse fuse wget ntfs-3g || {
    echo "[-] 依赖安装失败"
    exit 1
  }
  modprobe fuse || true
  # 确保/root目录可写
  chmod 700 /root
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/8：检查权限 ====="
[[ $EUID -ne 0 ]] && { echo "[-] 需要root权限"; exit 1; }

install_deps

echo "===== 步骤2/8：挂载NTFS分区 ====="
mkdir -p /root/ntfs
if mount | grep -q "$NTFS_PARTITION"; then
  echo "[+] NTFS分区已挂载"
else
  ntfsfix "$NTFS_PARTITION"
  mount -t ntfs-3g -o ro "$NTFS_PARTITION" /root/ntfs 2>/dev/null || {
    echo "[!] 以读写模式挂载NTFS"
    mount -t ntfs-3g -o rw "$NTFS_PARTITION" /root/ntfs
  }
fi

echo "===== 步骤3/8：获取ISO文件 ====="
if [[ ! -f "$ISO_PATH" ]]; then
  echo "[!] 下载ISO文件..."
  mkdir -p "$(dirname "$ISO_PATH")"
  wget -q --show-progress -O "$ISO_PATH.part" "$MANJARO_ISO_URL"
  mv "$ISO_PATH.part" "$ISO_PATH"
fi

echo "===== 步骤4/8：挂载ISO ====="
mkdir -p /root/iso
mount -o loop "$ISO_PATH" /root/iso || {
  echo "[-] ISO挂载失败，校验文件：$(md5sum "$ISO_PATH")"
  exit 1
}

echo "===== 步骤5/8：准备系统分区 ====="
read -rp "确认格式化 $TARGET_PARTITION? [y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION"
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR"

echo "===== 步骤6/8：构建联合文件系统 ====="
SFS_LAYERS=(
  /root/iso/manjaro/x86_64/rootfs.sfs
  /root/iso/manjaro/x86_64/desktopfs.sfs
  /root/iso/manjaro/x86_64/mhwdfs.sfs
)

# 创建临时挂载点（路径改为/root）
UNION_BASE="/root/union"
mkdir -p "$UNION_BASE"/{ro,rw,combined}

# 挂载所有只读层
declare -a ro_dirs
for idx in "${!SFS_LAYERS[@]}"; do
  layer_dir="$UNION_BASE/ro/layer$idx"
  mkdir -p "$layer_dir"
  mount -t squashfs -o loop,ro "${SFS_LAYERS[$idx]}" "$layer_dir"
  ro_dirs+=("$layer_dir")
done

# 创建可写层（内存中）
mkdir -p /tmp/unionfs_rw

# 联合挂载（关键参数优化）
unionfs -o cow,allow_other,nonempty,auto_cache,sync_read \
        /tmp/unionfs_rw=RW:$(IFS=:; echo "${ro_dirs[*]}") \
        "$UNION_BASE/combined"

echo "===== 步骤7/8：同步到系统分区 ====="
# 添加排除规则并设置重试机制
max_retry=3
for ((i=1; i<=$max_retry; i++)); do
  rsync -aHAXv --delete --ignore-errors \
    --exclude='/.unionfs/' \
    --exclude='/*.sfs' \
    --exclude='/usr/share/icons/Papirus/64x64/apps/appimagekit-*' \
    --exclude='/var/cache/' \
    "$UNION_BASE/combined/" "$MOUNT_DIR/" && break
  
  echo "[!] rsync失败，重试 $i/$max_retry..."
  sleep 2
done

# 强制处理只读文件
find "$MOUNT_DIR" -name '*.svg' -exec chattr -i {} \; -delete 2>/dev/null || true

echo "===== 步骤8/8：系统配置 ====="
# 生成fstab（使用绝对路径）
genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"

# 挂载系统目录（添加错误检查）
for fs in dev proc sys; do
  mount --bind /$fs "$MOUNT_DIR/$fs" || {
    echo "[-] 挂载/$fs失败"
    exit 1
  }
done

# 使用chroot安装引导（添加环境变量）
chroot "$MOUNT_DIR" /bin/bash -c "
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  grub-install --target=i386-pc --recheck "$TARGET_DISK"
  grub-mkconfig -o /boot/grub/grub.cfg
" || exit 1

echo -e "\n\e[32m[√] 安装成功！耗时: ${SECONDS}秒\e[0m"
echo "重启命令：umount -R $MOUNT_DIR && reboot"
