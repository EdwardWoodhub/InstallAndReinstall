# 运行环境
这里脚本运行环境是Debian Rescue,不是Debian10-live。

# 基本内容
下载ISO，安装系统，更新grub引导设置（比windows-install.sh更一步到位）。

# 基本操作步骤与注意事项
这是保留第二分区（NTFS格式）的数据前提下，第一分区重装parrotOS的脚本；过程中会下载parrotOS的iso到第二分区，且不删除。

过程中会要求设置用户和密码（否则，重启后无法通过VNC创建用户）。脚本最后会重启，重启后通过VNC登录用户，进入系统。

# 可行系统
parrotOS6.3.2，基于debian滚动版；感觉popOS最终会变到基于debian。
