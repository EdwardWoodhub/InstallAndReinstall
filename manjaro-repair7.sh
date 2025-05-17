#!/bin/bash
set -eo pipefail

# ======================
# 配置参数（安装前必须修改）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘设备
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区（EXT4）
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（NTFS存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录
ISO_PATH="/root/ntfs/iso/endeavouros.iso"
ENDEAVOUROS_ISO_URL="https://mirror.alpix.eu/endeavouros/iso/EndeavourOS_Mercury-Neo-2025.03.19.iso"

# ======================
# 初始化环境（强化清理）
# ======================
cleanup() {
  echo -e "\n===== 执行清理操作 ====="
  local unmount_points=(
    "${MOUNT_DIR}/dev"
    "${MOUNT_DIR}/proc"
    "${MOUNT_DIR}/sys"
    "/mnt/iso"
    "/mnt/squashfs"
    "${MOUNT_DIR}"
    "/root/ntfs"
  )

  for point in "${unmount_points[@]}"; do
    if mountpoint -q "${point}"; then
      echo "[清理] 卸载 ${point}"
      umount -l "${point}" 2>/dev/null || true
      sleep 0.3
    fi
  done

  rm -rf "/mnt/iso" "/mnt/squashfs" 2>/dev/null || true
  [ -d "/root/ntfs" ] && rmdir "/root/ntfs" 2>/dev/null || true
}
trap cleanup EXIT

# ======================
# 安装依赖（解决GRUB问题）
# ======================
install_deps() {
  echo "===== 安装系统依赖 ====="
  # 移除冲突的fuse3
  # apt-get remove --purge fuse3 -y 2>/dev/null || true
  # apt-mark hold fuse3 2>/dev/null || true

  # Debian软件源配置
  if grep -qi "debian" /etc/os-release; then
    echo "[系统] 配置Debian源"
    sed -i '/deb .* main/ s/main$/main contrib non-free/g' /etc/apt/sources.list
    apt-get update -qq
  fi

  # 安装核心组件
  apt-get install -y --no-install-recommends \
    squashfs-tools \
    ntfs-3g \
    wget \
    dosfstools \
    grub-pc \
    grub-common \
    efibootmgr || {
    echo "[-] 依赖安装失败"
    exit 1
  }

  # 验证关键命令
  for cmd in grub-install unsquashfs ntfsfix; do
    if ! command -v $cmd &>/dev/null; then
      echo "[-] 命令缺失: $cmd"
      exit 1
    fi
  done
}

# ======================
# NTFS智能挂载
# ======================
mount_ntfs() {
  echo "===== 初始化NTFS分区 ====="
  mkdir -p "/root/ntfs"

  if mount | grep -q "${NTFS_PARTITION}"; then
    echo "[NTFS] 分区已挂载，跳过初始化"
    return 0
  fi

  # 分区修复流程
  echo "[NTFS] 检查文件系统"
  if ! ntfsfix  "${NTFS_PARTITION}"; then
    echo "[!] 尝试强制卸载后修复"
    umount -l "${NTFS_PARTITION}" 2>/dev/null || true
    ntfsfix  "${NTFS_PARTITION}" || exit 1
  fi

  # 挂载参数
  local mount_opts="windows_names,uid=$(id -u),gid=$(id -g),nofail"
  if [ -f "${ISO_PATH}" ]; then
    echo "[NTFS] 以只读模式挂载"
    mount -t ntfs-3g -o "ro,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs" || {
      echo "[!] 切换到读写模式挂载"
      mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs"
    }
  else
    echo "[NTFS] 以读写模式挂载（用于下载ISO）"
    mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs" || exit 1
  fi

  # 最终验证
  mountpoint -q "/root/ntfs" || {
    echo "[-] NTFS挂载最终失败"
    exit 1
  }
}

# ======================
# ISO文件处理
# ======================
handle_iso() {
  echo "===== 处理ISO文件 ====="
  if [ -f "${ISO_PATH}" ]; then
    echo "[检测] 使用现有ISO文件"
    echo "     文件大小: $(du -h "${ISO_PATH}" | cut -f1)"
    echo "     SHA256: $(sha256sum "${ISO_PATH}" | cut -d' ' -f1)"
  else
    echo "[下载] 开始下载EndeavourOS ISO"
    mkdir -p "$(dirname "${ISO_PATH}")"
    if ! wget -q --show-progress -c -O "${ISO_PATH}.part" "${ENDEAVOUROS_ISO_URL}"; then
      echo "[-] 下载失败，可能原因："
      echo "    1. 网络连接故障（curl测试: $(curl -Is https://mirror.alpix.eu | head -1)）"
      echo "    2. 磁盘空间不足（剩余: $(df -h "$(dirname "${ISO_PATH}")" | awk 'NR==2{print $4}')"
      exit 1
    fi
    mv "${ISO_PATH}.part" "${ISO_PATH}"
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/7：环境验证 ====="
[ $EUID -ne 0 ] && { echo "[-] 需要root权限"; exit 1; }
[ ! -e "${TARGET_DISK}" ] && { echo "[-] 磁盘不存在: ${TARGET_DISK}"; exit 1; }

install_deps
mount_ntfs
handle_iso

echo "===== 步骤2/7：挂载ISO镜像 ====="
mkdir -p /mnt/iso
mount -o loop,ro "${ISO_PATH}" /mnt/iso || {
  echo "[-] ISO挂载失败，可能原因："
  echo "    1. 文件损坏（实际大小: $(du -h "${ISO_PATH}" | cut -f1)）"
  echo "    2. 内核不支持loop设备（检查: ls /dev/loop*）"
  exit 1
}

echo "===== 步骤3/7：准备系统分区 ====="
read -rp "即将格式化 ${TARGET_PARTITION}，所有数据将丢失！确认继续？[y/N] " confirm
if [[ ! "${confirm,,}" =~ ^y ]]; then
  echo "[用户] 安装已取消"
  exit 0
fi

echo "[分区] 创建EXT4文件系统"
mkfs.ext4 -F -L "EndeavourOS" "${TARGET_PARTITION}" || {
  echo "[-] 格式化失败，磁盘状态："
  lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT "${TARGET_DISK}"
  exit 1
}

mkdir -p "${MOUNT_DIR}"
mount "${TARGET_PARTITION}" "${MOUNT_DIR}" || exit 1

echo "===== 步骤4/7：解压系统文件 ====="
SFS_PATH="/mnt/iso/arch/x86_64/airootfs.sfs"
echo "[解压] 使用unsquashfs解压系统"
if ! unsquashfs -f -d "${MOUNT_DIR}" "${SFS_PATH}"; then
  echo "[-] 解压失败，检查："
  echo "    1. 存储空间（剩余: $(df -h "${MOUNT_DIR}" | awk 'NR==2{print $4}')）"
  echo "    2. 文件权限（尝试: chmod 755 ${MOUNT_DIR}）"
  exit 1
fi

echo "===== 步骤5/7：系统配置 ====="
echo "[配置] 生成fstab文件"
genfstab -U "${MOUNT_DIR}" > "${MOUNT_DIR}/etc/fstab" || {
  echo "[-] fstab生成失败"
  exit 1
}

echo "===== 步骤6/7：安装引导程序 ====="
for fs in dev proc sys; do
  mount --bind "/${fs}" "${MOUNT_DIR}/${fs}" || {
    echo "[-] 挂载/${fs}失败"
    exit 1
  }
done

echo "[引导] 配置GRUB环境"
cat > "${MOUNT_DIR}/grub_install.sh" <<'EOF'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
grub-install --target=i386-pc --recheck "$1"
grub-mkconfig -o /boot/grub/grub.cfg
EOF

chmod +x "${MOUNT_DIR}/grub_install.sh"
chroot "${MOUNT_DIR}" /grub_install.sh "${TARGET_DISK}" || {
  echo "[-] GRUB安装失败，可能原因："
  echo "    1. 目标磁盘错误（当前选择: ${TARGET_DISK}）"
  echo "    2. 系统分区未正确挂载（验证: mount | grep ${MOUNT_DIR}）"
  exit 1
}
rm -f "${MOUNT_DIR}/grub_install.sh"

echo "===== 步骤7/7：完成安装 ====="
echo -e "\n\e[32m[✓] EndeavourOS 安装成功！耗时: ${SECONDS}秒\e[0m"
echo "后续操作："
echo "1. 检查挂载状态：mount | grep -E '(${MOUNT_DIR}|/root/ntfs)'"
echo "2. 安全卸载：umount -R ${MOUNT_DIR}"
echo "3. 重启系统：reboot"
echo "4. 进入系统后建议："
echo "   sudo pacman -Syu"
echo "   sudo pacman -S xfce4 xfce4-goodies lightdm"
echo "   sudo systemctl enable lightdm"
