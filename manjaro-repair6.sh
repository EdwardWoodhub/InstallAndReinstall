#!/bin/bash
set -eo pipefail

# ======================
# 配置参数（安装前必须修改）
# ======================
TARGET_DISK="/dev/sda"             # 目标磁盘设备
TARGET_PARTITION="${TARGET_DISK}1" # 系统分区（EXT4）
NTFS_PARTITION="${TARGET_DISK}2"   # 数据分区（NTFS存放ISO）
MOUNT_DIR="/root/system"           # 系统挂载目录
ISO_PATH="/root/ntfs/iso/manjaro.iso"
MANJARO_ISO_URL="https://download.manjaro.org/xfce/25.0.1/manjaro-xfce-25.0.1-250508-linux612.iso"

# ======================
# 初始化环境（强化清理）
# ======================
cleanup() {
  echo -e "\n===== 执行清理操作 ====="
  # 卸载顺序：深层 -> 浅层
  local unmount_points=(
    "${MOUNT_DIR}/dev"
    "${MOUNT_DIR}/proc"
    "${MOUNT_DIR}/sys"
    "/mnt/squashfs"
    "/mnt/iso"
    "${MOUNT_DIR}"
    "/root/ntfs"
  )

  for point in "${unmount_points[@]}"; do
    if mountpoint -q "${point}"; then
      echo "[清理] 卸载 ${point}"
      umount -l "${point}" 2>/dev/null || true
      sleep 0.3  # 防止设备忙
    fi
  done

  # 删除残留目录
  rm -rf "/mnt/iso" "/mnt/squashfs" 2>/dev/null || true
  [ -d "/root/ntfs" ] && rmdir "/root/ntfs" 2>/dev/null || true
}
trap cleanup EXIT

# ======================
# 安装依赖（主动处理fuse3）
# ======================
install_deps() {
  echo "===== 安装系统依赖 ====="
  # 强制移除并锁定fuse3
  apt-get remove --purge fuse3 -y 2>/dev/null || true
  apt-mark hold fuse3 2>/dev/null || true

  # Debian系统配置
  if grep -qi "debian" /etc/os-release; then
    echo "[系统] 配置Debian软件源"
    sed -i '/deb .* main/ s/main$/main contrib non-free/g' /etc/apt/sources.list
    dpkg --configure -a
  fi

  # 更新并安装核心组件
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    fuse3 \
    squashfs-tools \
    ntfs-3g \
    wget \
    dosfstools \
    grub-common || {
    echo "[-] 依赖安装失败"
    exit 1
  }


  # 加载内核模块
  modprobe fuse || {
    echo "[-] 无法加载fuse模块"
    dmesg | tail -n 20
    exit 1
  }
}

# ======================
# NTFS智能挂载方案
# ======================
mount_ntfs() {
  echo "===== 初始化NTFS分区 ====="
  mkdir -p "/root/ntfs"

  # 检查现有挂载
  if mount | grep -q "${NTFS_PARTITION}"; then
    echo "[NTFS] 分区已挂载，跳过初始化"
    return 0
  fi

  # 分区修复流程
  echo "[NTFS] 检查文件系统"
  if ! ntfsfix  "${NTFS_PARTITION}"; then
    echo "[!] 尝试强制卸载后修复"
    umount -l "${NTFS_PARTITION}" 2>/dev/null || true
    ntfsfix  "${NTFS_PARTITION}" || {
      echo "[-] NTFS修复失败"
      exit 1
    }
  fi

  # 智能挂载策略
  local mount_opts="windows_names,uid=$(id -u),gid=$(id -g),nofail"
  if [ -f "${ISO_PATH}" ]; then
    echo "[NTFS] 以只读模式挂载"
    mount -t ntfs-3g -o "ro,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs" || {
      echo "[!] 只读挂载失败，尝试读写模式"
      mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs"
    }
  else
    echo "[NTFS] 以读写模式挂载（用于下载ISO）"
    mount -t ntfs-3g -o "rw,${mount_opts}" "${NTFS_PARTITION}" "/root/ntfs" || {
      echo "[-] NTFS挂载失败"
      exit 1
    }
  fi

  # 最终验证
  mountpoint -q "/root/ntfs" || {
    echo "[-] NTFS挂载最终失败"
    exit 1
  }
}

# ======================
# ISO文件处理（增强校验）
# ======================
handle_iso() {
  echo "===== 处理ISO文件 ====="
  if [ -f "${ISO_PATH}" ]; then
    echo "[检测] 使用现有ISO文件"
    echo "       MD5校验码: $(md5sum "${ISO_PATH}" | cut -d' ' -f1)"
  else
    echo "[下载] 开始下载ISO镜像"
    mkdir -p "$(dirname "${ISO_PATH}")"
    if ! wget -q --show-progress -c -O "${ISO_PATH}.part" "${MANJARO_ISO_URL}"; then
      echo "[-] 下载失败，可能原因："
      echo "    1. 网络连接故障（状态码：$?）"
      echo "    2. 磁盘空间不足（当前剩余：$(df -h "$(dirname "${ISO_PATH}")" | awk 'NR==2{print $4}')）"
      exit 1
    fi
    mv "${ISO_PATH}.part" "${ISO_PATH}"
    echo "[校验] 下载完成，大小：$(du -h "${ISO_PATH}" | cut -f1)"
  fi
}

# ======================
# 主安装流程
# ======================
echo "===== 步骤1/8：环境验证 ====="
[ $EUID -ne 0 ] && { echo "[-] 请以root权限运行"; exit 1; }
[ ! -e "${TARGET_DISK}" ] && { echo "[-] 磁盘不存在: ${TARGET_DISK}"; exit 1; }

install_deps
mount_ntfs
handle_iso

echo "===== 步骤2/8：挂载ISO镜像 ====="
mkdir -p /mnt/iso
mount -o loop,ro "${ISO_PATH}" /mnt/iso || {
  echo "[-] ISO挂载失败，可能原因："
  echo "    1. 文件损坏（实际大小：$(du -h "${ISO_PATH}" | cut -f1)）"
  echo "    2. 内核不支持loop设备（检查: ls /dev/loop*）"
  exit 1
}

echo "===== 步骤3/8：准备系统分区 ====="
read -rp "即将格式化 ${TARGET_PARTITION}，所有数据将丢失！确认继续？[y/N] " confirm
if [[ ! "${confirm,,}" =~ ^y ]]; then
  echo "[用户] 安装已取消"
  exit 0
fi

echo "[分区] 创建EXT4文件系统"
if ! mkfs.ext4 -F -L "SysRoot" "${TARGET_PARTITION}"; then
  echo "[-] 格式化失败，磁盘状态："
  lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT "${TARGET_DISK}"
  exit 1
fi

mkdir -p "${MOUNT_DIR}"
mount "${TARGET_PARTITION}" "${MOUNT_DIR}" || exit 1

echo "===== 步骤4/8：解压基础系统 ====="
SFS_PATH="/mnt/iso/manjaro/x86_64/rootfs.sfs"
echo "[解压] 使用unsquashfs解压"
if ! unsquashfs -f -d "${MOUNT_DIR}" "${SFS_PATH}"; then
  echo "[-] 解压失败，可能原因："
  echo "    1. 存储空间不足（需要至少5GB）"
  echo "    2. 文件系统权限问题（当前剩余空间：$(df -h "${MOUNT_DIR}" | awk 'NR==2{print $4}')）"
  exit 1
fi

echo "===== 步骤5/8：系统基础配置 ====="
echo "[配置] 生成fstab文件"
genfstab -U "${MOUNT_DIR}" > "${MOUNT_DIR}/etc/fstab" || {
  echo "[-] fstab生成失败"
  exit 1
}

echo "===== 步骤6/8：安装引导程序 ====="
for fs in dev proc sys; do
  mount --bind "/${fs}" "${MOUNT_DIR}/${fs}" || {
    echo "[-] 挂载/${fs}失败"
    exit 1
  }
done

echo "[引导] 安装GRUB到磁盘"
chroot "${MOUNT_DIR}" /bin/bash -c '
  export PATH=/usr/sbin:/usr/bin:/sbin:/bin
  grub-install --target=i386-pc --recheck "'"${TARGET_DISK}"'" || exit 1
  grub-mkconfig -o /boot/grub/grub.cfg
' || {
  echo "[-] GRUB安装失败"
  exit 1
}

echo "===== 步骤7/8：清理临时文件 ====="
find "${MOUNT_DIR}" -name '*.pacnew' -delete 2>/dev/null || true
rm -f "${MOUNT_DIR}/etc/machine-id"

echo "===== 步骤8/8：安装完成 ====="
echo -e "\n\e[32m[✓] 系统安装成功！耗时: ${SECONDS}秒\e[0m"
echo "后续操作建议："
echo "1. 检查挂载状态：mount | grep -E '(${MOUNT_DIR}|/root/ntfs)'"
echo "2. 安全卸载：umount -R ${MOUNT_DIR}"
echo "3. 重启系统：reboot"
echo "4. 进入系统后安装桌面环境："
echo "   sudo pacman -Syu"
echo "   sudo pacman -S xfce4 xfce4-goodies lightdm"
echo "   sudo systemctl enable lightdm"
