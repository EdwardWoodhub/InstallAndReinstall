#!/bin/bash
set -eo pipefail

# ======================
# 配置参数（安装前必须修改）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘设备
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载点
ISO_PATH="/root/ntfs/iso/manjaro.iso"
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化环境（增强版清理流程）
# ======================
cleanup() {
  echo -e "\n===== 执行清理操作 ====="
  
  # 卸载顺序：从深层到浅层
  local unmount_points=(
    "${MOUNT_DIR}/dev"
    "${MOUNT_DIR}/proc"
    "${MOUNT_DIR}/sys"
    "/root/union/combined"
    "/tmp/unionfs_rw"
    "/root/union/ro/layer"*
    "/root/iso"
    "/root/ntfs"
    "${MOUNT_DIR}"
  )

  # 卸载所有挂载点
  for point in "${unmount_points[@]}"; do
    if mountpoint -q "${point}"; then
      echo "[清理] 卸载 ${point}"
      umount -l "${point}" 2>/dev/null || true
      sleep 0.5  # 防止设备忙
    fi
  done

  # 处理残留目录
  echo "[清理] 删除临时目录"
  rm -rf "/root/union" "/tmp/unionfs_rw" 2>/dev/null || true

  # 确保SquashFS层卸载
  find /root/union/ro -maxdepth 1 -type d -name "layer*" 2>/dev/null | while read -r layer; do
    if mountpoint -q "${layer}"; then
      umount -l "${layer}" 2>/dev/null || true
    fi
  done

  # 最终清理
  rm -rf /root/{ntfs,iso,system} 2>/dev/null || true
}
trap cleanup EXIT

# ======================
# 安装依赖工具（增强兼容性）
# ======================
install_deps() {
  echo "===== 安装系统依赖 ====="
  
  # 清理冲突包
  #apt-get remove --purge fuse3 -y 2>/dev/null || true
  #apt-mark hold fuse3 2>/dev/null || true

  # Debian系统配置
  if grep -qi "debian" /etc/os-release; then
    echo "[系统] 配置Debian软件源"
    sed -i '/deb .* main/ s/main$/main contrib non-free/g' /etc/apt/sources.list
    dpkg --configure -a
  fi

  # 更新软件源
  apt-get update -qq
  
  # 安装核心组件（指定fuse2版本）
  echo "[系统] 安装必要软件包"
  apt-get install -y --no-install-recommends \
    fuse3 \
    squashfs-tools \
    unionfs-fuse \
    ntfs-3g \
    wget \
    dosfstools \
    parted \
    grub-common || {
    echo "[-] 软件包安装失败"
    exit 1
  }

  # 加载内核模块
  if ! modprobe fuse; then
    echo "[-] FUSE模块加载失败"
    dmesg | tail -n 20
    exit 1
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/9：环境验证 ====="
[ $EUID -ne 0 ] && { echo "[-] 必须使用root权限运行"; exit 1; }
[ ! -e "${TARGET_DISK}" ] && { echo "[-] 磁盘设备不存在: ${TARGET_DISK}"; exit 1; }

install_deps

echo "===== 步骤2/9：准备NTFS分区 ====="
mkdir -p /root/ntfs
if mount | grep -q "${NTFS_PARTITION}"; then
  echo "[存储] NTFS分区已挂载"
else
  # NTFS修复流程
  echo "[存储] 修复NTFS文件系统"
  if ! ntfsfix  "${NTFS_PARTITION}"; then
    echo "[!] 尝试强制卸载后修复"
    umount -l "${NTFS_PARTITION}" 2>/dev/null || true
    ntfsfix  "${NTFS_PARTITION}" || {
      echo "[-] NTFS修复失败"
      exit 1
    }
  fi

  # 智能挂载策略
  mount_opts="windows_names,uid=$(id -u),gid=$(id -g)"
  if ! mount -t ntfs-3g -o "ro,${mount_opts}" "${NTFS_PARTITION}" /root/ntfs; then
    echo "[存储] 切换到读写模式挂载"
    mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" /root/ntfs || {
      echo "[-] NTFS挂载失败"
      exit 1
    }
  fi
fi

echo "===== 步骤3/9：获取ISO文件 ====="
if [ -f "${ISO_PATH}" ]; then
  echo "[存储] 使用现有ISO文件"
else
  echo "[下载] 开始下载Manjaro ISO"
  mkdir -p "$(dirname "${ISO_PATH}")"
  if ! wget -q --show-progress -c -O "${ISO_PATH}.part" "${MANJARO_ISO_URL}"; then
    echo "[-] 下载失败，请检查："
    echo "    - 网络连接"
    echo "    - 磁盘空间（剩余空间需大于5GB）"
    exit 1
  fi
  mv "${ISO_PATH}.part" "${ISO_PATH}"
fi

echo "===== 步骤4/9：挂载ISO镜像 ====="
mkdir -p /root/iso
if ! mount -o loop,ro "${ISO_PATH}" /root/iso; then
  echo "[-] ISO挂载失败"
  echo "可能原因："
  echo "    1. ISO文件损坏（MD5: $(md5sum "${ISO_PATH}" | cut -d' ' -f1)）"
  echo "    2. 缺少loop设备支持（检查/dev/loop*）"
  exit 1
fi

echo "===== 步骤5/9：准备系统分区 ====="
read -rp "即将格式化 ${TARGET_PARTITION}，所有数据将丢失！确认继续？[y/N] " confirm
if [[ ! "${confirm,,}" =~ ^y ]]; then
  echo "[用户] 安装已取消"
  exit 0
fi

echo "[存储] 创建EXT4文件系统"
if ! mkfs.ext4 -F -L "SysRoot" "${TARGET_PARTITION}"; then
  echo "[-] 格式化失败，磁盘状态："
  parted -l
  exit 1
fi

mkdir -p "${MOUNT_DIR}"
mount "${TARGET_PARTITION}" "${MOUNT_DIR}" || exit 1

echo "===== 步骤6/9：构建联合文件系统 ====="
SFS_LAYERS=(
  "/root/iso/manjaro/x86_64/rootfs.sfs"
  "/root/iso/manjaro/x86_64/desktopfs.sfs"
  "/root/iso/manjaro/x86_64/mhwdfs.sfs"
)

UNION_BASE="/root/union"
mkdir -p "${UNION_BASE}"/{ro,rw,combined}

# 挂载SquashFS层
declare -a ro_dirs=()
for idx in "${!SFS_LAYERS[@]}"; do
  layer_dir="${UNION_BASE}/ro/layer${idx}"
  mkdir -p "${layer_dir}"
  if ! mount -t squashfs -o loop,ro "${SFS_LAYERS[$idx]}" "${layer_dir}"; then
    echo "[-] 无法挂载SFS层: ${SFS_LAYERS[$idx]}"
    exit 1
  fi
  ro_dirs+=("${layer_dir}")
  echo "[挂载] 已挂载层 ${idx}: ${SFS_LAYERS[$idx]}"
done

# 创建可写层（带错误回退）
echo "[存储] 准备可写层"
mkdir -p /tmp/unionfs_rw
if ! mount -t tmpfs -o size=2G tmpfs /tmp/unionfs_rw; then
  echo "[!] 内存挂载失败，使用磁盘回退方案"
  mkdir -p /tmp/unionfs_rw_fallback
  mount --bind /tmp/unionfs_rw_fallback /tmp/unionfs_rw
fi

# 联合挂载（带权限检查）
echo "[系统] 创建联合视图"
unionfs_opts=(
  "-o" "cow"
  "-o" "allow_other"
  "-o" "nonempty"
  "-o" "auto_cache"
  "-o" "sync_read"
  "-o" "default_permissions"
)
if ! unionfs "${unionfs_opts[@]}" \
   "/tmp/unionfs_rw=RW:$(IFS=:; echo "${ro_dirs[*]}")" \
   "${UNION_BASE}/combined"; then
  echo "[-] UnionFS挂载失败"
  exit 1
fi

echo "===== 步骤7/9：系统文件同步 ====="
max_retries=3
retry_delay=5
for ((attempt=1; attempt<=max_retries; attempt++)); do
  echo "[同步] 开始第 ${attempt}/${max_retries} 次尝试"
  if rsync -aHAXv --delete --ignore-errors \
       --exclude='/.unionfs/' \
       --exclude='/*.sfs' \
       --exclude='/var/cache/' \
       --exclude='/usr/share/icons/Papirus/64x64/apps/appimagekit-*' \
       "${UNION_BASE}/combined/" "${MOUNT_DIR}/"; then
    break
  fi
  
  if [ $attempt -eq $max_retries ]; then
    echo "[-] 文件同步失败超过最大重试次数"
    exit 1
  fi
  
  echo "[!] 同步失败，${retry_delay}秒后重试..."
  sleep $retry_delay
done

echo "===== 步骤8/9：后期处理 ====="
echo "[系统] 清理冲突文件"
find "${MOUNT_DIR}" \( -name '*.svg' -o -name '*.cache' \) \
  -exec chattr -i {} \; -delete 2>/dev/null || true

echo "[系统] 生成fstab文件"
genfstab -U "${MOUNT_DIR}" > "${MOUNT_DIR}/etc/fstab" || {
  echo "[-] fstab生成失败"
  exit 1
}

echo "===== 步骤9/9：安装引导程序 ====="
for fs in dev proc sys; do
  if ! mount --bind "/${fs}" "${MOUNT_DIR}/${fs}"; then
    echo "[-] 挂载/${fs}失败"
    exit 1
  fi
done

echo "[引导] 安装GRUB"
chroot "${MOUNT_DIR}" /bin/bash -c '
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  grub-install --target=i386-pc --recheck "'"${TARGET_DISK}"'" || exit 1
  grub-mkconfig -o /boot/grub/grub.cfg
' || {
  echo "[-] GRUB安装失败"
  exit 1
}

echo -e "\n\e[32m[✓] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo "重启前请执行："
echo "   umount -R ${MOUNT_DIR}"
echo "   reboot"
