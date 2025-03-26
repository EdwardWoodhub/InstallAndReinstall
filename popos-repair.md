这是保留第二分区（NTFS格式）的数据前提下，第一分区重装popos的脚本；脚本最后会重启，重启后通过VNC设置用户，进入系统。这里脚本运行环境是Debian Rescue,不是Debian10-live。过程中会下载popos的iso到第二分区，且不删除。
脚本内容：下载ISO，安装系统，更新grub引导设置（比windows-install.sh更一步到位）。
# 可行系统
popos22.04lts
