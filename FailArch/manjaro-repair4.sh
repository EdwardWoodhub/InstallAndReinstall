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
    [ -d $mnt ] && rmdir $mnt 2>/dev/null || true
  done
  rm -rf /root/union /tmp/unionfs_rw
}
trap cleanup EXIT

# ======================
# 安装必需工具（无fuse3版）
# ======================
install_deps() {
  echo "===== 安装依赖工具 ====="
  # 清除潜在冲突
  #apt-get remove --purge fuse3 -y 2>/dev/null || true
  #apt-mark hold fuse3 2>/dev/null || true

  # Debian软件源配置
  if grep -qi "debian" /etc/os-release; then
    echo "[+] 配置Debian软件源"
    sed -i '/deb .* main/ s/main$/main contrib non-free/g' /etc/apt/sources.list
    dpkg --configure -a
  fi

  # 更新并安装核心组件
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    fuse3 \
    squashfs-tools \
    unionfs-fuse \
    ntfs-3g \
    wget \
    dosfstools \
    parted || {
    echo "[-] 依赖安装失败，尝试手动修复："
    echo "1. 检查网络连接"
    echo "2. 运行 apt-get install -f"
    exit 1
  }

  # 加载内核模块
  if ! modprobe fuse; then
    echo "[-] FUSE模块加载失败，尝试更新内核"
    apt-get install -y linux-image-amd64
    reboot
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/8：环境验证 ====="
[ $EUID -ne 0 ] && { echo "[-] 请以root权限运行"; exit 1; }
[ ! -e $TARGET_DISK ] && { echo "[-] 目标磁盘不存在: $TARGET_DISK"; exit 1; }

install_deps

echo "===== 步骤2/8：挂载NTFS分区 ====="
mkdir -p /root/ntfs
if mount | grep -q $NTFS_PARTITION; then
  echo "[+] NTFS分区已挂载"
else
  echo "[+] 修复NTFS文件系统"
  ntfsfix  $NTFS_PARTITION || {
    echo "[-] NTFS修复失败，尝试卸载后重试..."
    umount -l $NTFS_PARTITION 2>/dev/null || true
    ntfsfix  $NTFS_PARTITION
  }

  # 智能挂载策略
  mount_opts="ro,big_writes,windows_names,uid=$(id -u),gid=$(id -g)"
  if ! mount -t ntfs-3g -o $mount_opts $NTFS_PARTITION /root/ntfs; then
    echo "[!] 切换到读写模式挂载"
    mount -t ntfs-3g -o rw,$mount_opts $NTFS_PARTITION /root/ntfs
  fi
fi

echo "===== 步骤3/8：获取ISO文件 ====="
if [ -f "$ISO_PATH" ]; then
  echo "[+] 使用现有ISO文件"
else
  echo "[!] 开始下载ISO镜像..."
  mkdir -p $(dirname $ISO_PATH)
  if ! wget -q --show-progress -O "$ISO_PATH.part" "$MANJARO_ISO_URL"; then
    echo "[-] 下载失败，错误码: $?"
    echo "    请检查URL有效性: $MANJARO_ISO_URL"
    exit 1
  fi
  mv "$ISO_PATH.part" "$ISO_PATH"
fi

echo "===== 步骤4/8：挂载ISO镜像 ====="
mkdir -p /root/iso
if ! mount -o loop "$ISO_PATH" /root/iso; then
  echo "[-] ISO挂载失败，可能原因："
  echo "1. ISO文件损坏，MD5: $(md5sum "$ISO_PATH")"
  echo "2. 缺少loop设备支持，检查 /dev/loop*"
  exit 1
fi

echo "===== 步骤5/8：准备系统分区 ====="
read -rp "即将格式化 $TARGET_PARTITION，确认继续？[y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
  echo "[!] 用户取消操作"
  exit 0
fi

echo "[+] 创建EXT4文件系统"
if ! mkfs.ext4 -F -L "SysRoot" $TARGET_PARTITION; then
  echo "[-] 格式化失败，检查磁盘状态："
  parted -l
  exit 1
fi

mkdir -p $MOUNT_DIR
mount $TARGET_PARTITION $MOUNT_DIR || exit 1

echo "===== 步骤6/8：构建联合文件系统 ====="
SFS_LAYERS=(
  /root/iso/manjaro/x86_64/rootfs.sfs
  /root/iso/manjaro/x86_64/desktopfs.sfs
  /root/iso/manjaro/x86_64/mhwdfs.sfs
)

UNION_BASE="/root/union"
mkdir -p $UNION_BASE/{ro,rw,combined}

# 挂载SquashFS层
declare -a ro_dirs=()
for idx in "${!SFS_LAYERS[@]}"; do
  layer_dir="$UNION_BASE/ro/layer$idx"
  mkdir -p $layer_dir
  if ! mount -t squashfs -o loop,ro "${SFS_LAYERS[$idx]}" $layer_dir; then
    echo "[-] 层挂载失败: ${SFS_LAYERS[$idx]}"
    exit 1
  fi
  ro_dirs+=($layer_dir)
done

# 创建内存可写层
mkdir -p /tmp/unionfs_rw
mount -t tmpfs -o size=2G tmpfs /tmp/unionfs_rw

# 联合挂载配置
unionfs -o cow,allow_other,nonempty,auto_cache,sync_read \
        /tmp/unionfs_rw=RW:$(IFS=:; echo "${ro_dirs[*]}") \
        $UNION_BASE/combined || {
  echo "[-] UnionFS挂载失败"
  exit 1
}

echo "===== 步骤7/8：系统文件部署 ====="
retry_count=0
max_retries=3
until [ $retry_count -ge $max_retries ]; do
  rsync -aHAXv --delete --ignore-errors \
    --exclude='/.unionfs/' \
    --exclude='/*.sfs' \
    --exclude='/var/cache/' \
    --exclude='/usr/share/icons/Papirus/64x64/apps/appimagekit-*' \
    $UNION_BASE/combined/ $MOUNT_DIR/ && break
  
  ((retry_count++))
  echo "[!] 文件同步失败，重试 $retry_count/$max_retries..."
  sleep $((retry_count * 2))
done

[ $retry_count -ge $max_retries ] && {
  echo "[-] 文件同步超过最大重试次数"
  exit 1
}

# 清理冲突文件
find $MOUNT_DIR \( -name '*.svg' -o -name '*.cache' \) \
  -exec chattr -i {} \; -delete 2>/dev/null || true

echo "===== 步骤8/8：系统初始化 ====="
echo "[+] 生成fstab文件"
genfstab -U $MOUNT_DIR > $MOUNT_DIR/etc/fstab || {
  echo "[-] fstab生成失败"
  exit 1
}

echo "[+] 安装引导加载程序"
for fs in dev proc sys; do
  mount --bind /$fs $MOUNT_DIR/$fs || {
    echo "[-] 挂载/$fs失败"
    exit 1
  }
done

chroot $MOUNT_DIR /bin/bash -c "
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  grub-install --target=i386-pc --recheck $TARGET_DISK || exit 1
  grub-mkconfig -o /boot/grub/grub.cfg
" || {
  echo "[-] GRUB安装失败"
  exit 1
}

echo -e "\n\e[32m[√] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo "重启前请确认："
echo "1. 拔除安装介质"
echo "2. 执行重启命令："
echo "   umount -R $MOUNT_DIR && reboot"
