# Debian 12/13 小服务器安装指南

本指南适用于 amd64 小服务器、N100 软路由主机和普通台式服务器。

## 安装前

1. 备份目标磁盘数据。
2. 从 Debian 官方下载 netinst ISO，并核对 SHA-256。
3. 推荐用 Ventoy；启动时先选 Normal mode。
4. 固件中优先使用 UEFI。Ventoy Secure Boot 认证失败时，可按 Ventoy 官方流程登记密钥，或临时关闭 Secure Boot。
5. 将服务器接到路由器 LAN 口；首次安装优先使用主板原生有线口，USB/Type‑C 扩展坞网卡留作备用。

## 安装流程

1. 选择 `Graphical install` 或 `Install`，两者结果相同。
2. 语言和键盘可按个人习惯；服务器命令建议保留英文用户名。
3. 网络失败可选择稍后配置，不必反复等待。
4. 主机名只用字母、数字和短横线。
5. root 密码留空时，首个普通用户通常会获得 sudo。
6. 单盘小服务器推荐引导分区 + LVM + 所有文件一个分区。
7. 软件选择只勾选 `SSH server` 和 `standard system utilities`，取消桌面。
8. 安装 GRUB 到系统盘，不要选安装 U 盘。
9. 重启前拔出安装 U 盘，或调整启动顺序。

## 首次本地登录

```bash
ip -br link
ip -4 -br address
ip route
```

没有地址或 SSH 时，插入包含本项目的 U 盘：

```bash
lsblk -f
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
cd /mnt/usb/debian-first-network-kit
sudo bash scripts/bootstrap-network.sh
```

多网口机器建议先看 `ip -br link`，再显式指定：

```bash
sudo bash scripts/bootstrap-network.sh --interface enp2s0
```

## 安装后

在路由器 DHCP 租约中为服务器绑定固定地址，比直接在服务器里写静态地址更容易维护，也避免切换网络时失联。

从另一台电脑连接：

```bash
ssh <用户>@<服务器IP>
```

首次连接核对指纹后输入 `yes`。不要开放公网 22 端口；远程访问优先使用 WireGuard、Tailscale 等 VPN。
