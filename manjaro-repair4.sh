#!/bin/bash
set -eo pipefail

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
  for mnt in /root/{ntfs,iso,union,system}; do
    umount -l $mnt 2>/dev/null || true
  done
  rm -rf /root/{ntfs,iso,union,system} /tmp/unionfs*
  [ -d "/root/ntfs" ] && rmdir /root/ntfs 2>/dev/null || true
}
trap cleanup EXIT

# ======================
# 安装必需工具（强化版依赖处理）
# ======================
install_deps() {
  echo "===== 安装依赖工具 ====="
  # 清理冲突包
  apt-get remove --purge fuse3 fuse -y 2>/dev/null || true
  
  # 配置软件源（Debian专用）
  if grep -qi "debian" /etc/os-release; then
    echo "[+] 配置Debian软件源"
    sed -i '/deb .* main/ s/main$/main contrib non-free/g' /etc/apt/sources.list
    dpkg --configure -a
  fi

  # 更新并修复基础环境
  apt-get update -qq
  apt-get install -f -y
  #apt-get autoremove -y

  # 安装指定版本软件包
  echo "[+] 安装核心组件"
  apt-get install -y --no-install-recommends \
    fuse=2.9.9-* \
    squashfs-tools \
    unionfs-fuse \
    ntfs-3g \
    wget \
    dosfstools \
    parted || {
    echo "[-] 依赖安装失败"
    exit 1
  }

  # 加载内核模块
  modprobe fuse || {
    echo "[-] 无法加载fuse模块"
    exit 1
  }
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/8：环境检查 ====="
[[ $EUID -ne 0 ]] && { echo "[-] 需要root权限"; exit 1; }
[ ! -e "$TARGET_DISK" ] && { echo "[-] 磁盘不存在: $TARGET_DISK"; exit 1; }

install_deps

echo "===== 步骤2/8：准备NTFS分区 ====="
mkdir -p /root/ntfs
if ! command -v ntfsfix &>/dev/null; then
  apt-get install -y ntfs-3g
fi

if mount | grep -q "$NTFS_PARTITION"; then
  echo "[+] NTFS分区已挂载"
else
  echo "[+] 修复NTFS分区"
  ntfsfix  "$NTFS_PARTITION" || {
    echo "[-] NTFS修复失败，尝试强制卸载..."
    umount -l "$NTFS_PARTITION" 2>/dev/null || true
    ntfsfix  "$NTFS_PARTITION"
  }

  # 智能挂载（优先只读）
  if ! mount -t ntfs-3g -o ro,big_writes,windows_names "$NTFS_PARTITION" /root/ntfs; then
    echo "[!] 以读写模式挂载NTFS"
    mount -t ntfs-3g -o rw,big_writes,windows_names "$NTFS_PARTITION" /root/ntfs
  fi
fi

echo "===== 步骤3/8：获取ISO文件 ====="
if [[ -f "$ISO_PATH" ]]; then
  echo "[+] 发现现有ISO文件"
else
  echo "[!] 开始下载ISO..."
  mkdir -p "$(dirname "$ISO_PATH")"
  wget -q --show-progress -O "$ISO_PATH.part" "$MANJARO_ISO_URL" || {
    echo "[-] 下载失败，检查网络连接"
    exit 1
  }
  mv "$ISO_PATH.part" "$ISO_PATH"
fi

echo "===== 步骤4/8：挂载ISO镜像 ====="
mkdir -p /root/iso
mount -o loop "$ISO_PATH" /root/iso || {
  echo "[-] ISO挂载失败，校验文件：$(md5sum "$ISO_PATH")"
  exit 1
}

echo "===== 步骤5/8：准备系统分区 ====="
read -rp "确认格式化 $TARGET_PARTITION? [y/N] " confirm
[[ "$confirm" =~ ^[Yy] ]] || exit 0

echo "[+] 格式化分区为EXT4"
mkfs.ext4 -F -L "SysRoot" "$TARGET_PARTITION"
mkdir -p "$MOUNT_DIR"
mount "$TARGET_PARTITION" "$MOUNT_DIR" || exit 1

echo "===== 步骤6/8：构建联合文件系统 ====="
SFS_LAYERS=(
  /root/iso/manjaro/x86_64/rootfs.sfs
  /root/iso/manjaro/x86_64/desktopfs.sfs
  /root/iso/manjaro/x86_64/mhwdfs.sfs
)

UNION_BASE="/root/union"
mkdir -p "$UNION_BASE"/{ro,rw,combined}

# 挂载SquashFS层
declare -a ro_dirs
for idx in "${!SFS_LAYERS[@]}"; do
  layer_dir="$UNION_BASE/ro/layer$idx"
  mkdir -p "$layer_dir"
  mount -t squashfs -o loop,ro "${SFS_LAYERS[$idx]}" "$layer_dir"
  ro_dirs+=("$layer_dir")
done

# 创建内存可写层
mkdir -p /tmp/unionfs_rw
mount -t tmpfs -o size=2G tmpfs /tmp/unionfs_rw

# 挂载UnionFS（强化参数）
unionfs -o cow,allow_other,nonempty,auto_cache,sync_read,default_permissions \
        /tmp/unionfs_rw=RW:$(IFS=:; echo "${ro_dirs[*]}") \
        "$UNION_BASE/combined"

echo "===== 步骤7/8：系统文件同步 ====="
max_retry=3
for ((i=1; i<=$max_retry; i++)); do
  rsync -aHAXv --delete --ignore-errors \
    --exclude='/.unionfs/' \
    --exclude='/*.sfs' \
    --exclude='/var/cache/' \
    --exclude='/usr/share/icons/Papirus/64x64/apps/appimagekit-*' \
    "$UNION_BASE/combined/" "$MOUNT_DIR/" && break
  
  echo "[!] rsync失败，重试 $i/$max_retry..."
  sleep 2
done

# 强制清理冲突文件
find "$MOUNT_DIR" \( -name '*.svg' -o -name '*.cache' \) -exec chattr -i {} \; -delete 2>/dev/null || true

echo "===== 步骤8/8：系统配置 ====="
echo "[+] 生成fstab"
genfstab -U "$MOUNT_DIR" > "$MOUNT_DIR/etc/fstab"

echo "[+] 安装引导程序"
for fs in dev proc sys; do
  mount --bind /$fs "$MOUNT_DIR/$fs"
done

chroot "$MOUNT_DIR" /bin/bash -c "
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  grub-install --target=i386-pc --recheck "$TARGET_DISK"
  grub-mkconfig -o /boot/grub/grub.cfg
" || {
  echo "[-] GRUB安装失败"
  exit 1
}

echo -e "\n\e[32m[√] 安装成功！耗时: ${SECONDS}秒\e[0m"
echo "重启命令："
echo "  umount -R $MOUNT_DIR && reboot"
