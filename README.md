# Debian 首次联网工具箱

[English](README.en.md)

面向 Debian 12（bookworm）和 Debian 13（trixie）小服务器的首次联网、APT 官方源修复与 SSH 启用工具。默认中文，可用 `--lang en` 切换英文。

它解决的是这条常见故障链：

```text
网线已插好
  → 网卡仍是 DOWN / 没有 DHCP 地址
  → DNS 无法解析
  → apt update 报软件源或 keyring 错误
  → openssh-server 没有 installation candidate
  → 无法从另一台电脑 SSH 登录
```

## 最快使用方式

把本仓库复制到 U 盘，插入 Debian 服务器。先在服务器本地登录，然后：

```bash
lsblk -f
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
cd /mnt/usb/debian-first-network-kit
sudo bash scripts/diagnose-network.sh
sudo bash scripts/bootstrap-network.sh
```

请把 `/dev/sdX1` 换成 `lsblk -f` 显示的 U 盘数据分区，绝对不要照抄磁盘名。

脚本会先显示即将使用的网卡、网络后端、配置文件和服务操作，确认后才修改。完成后会显示服务器 IP：

```bash
ssh <你的Debian用户名>@<服务器IP>
```

常用选项：

```bash
# 多块有线网卡时明确指定，推荐
sudo bash scripts/bootstrap-network.sh --interface enp2s0

# 无交互执行；多网卡有歧义时仍会拒绝猜测
sudo bash scripts/bootstrap-network.sh --yes

# 增加备用 DNS
sudo bash scripts/bootstrap-network.sh --dns 223.5.5.5

# 只恢复 DHCP/DNS，不修改 APT，也不安装 SSH
sudo bash scripts/bootstrap-network.sh --no-apt --no-ssh

# 英文界面
sudo bash scripts/bootstrap-network.sh --lang en
sudo bash scripts/diagnose-network.sh --lang en
```

## 安全边界

- 仅支持 Debian 12/bookworm、Debian 13/trixie；其他系统会停止。
- 只自动选择物理有线网卡，排除 Wi‑Fi、回环和常见虚拟网卡。
- 多网卡无法唯一判断时停止，要求 `--interface`。
- 检测到 NetworkManager、systemd-networkd、ifupdown 重复管理时停止。
- 发现 ifupdown 静态地址或可能抢先匹配的第三方 `.network` 文件时停止，不覆盖。
- 修改前生成唯一备份；使用锁防止两个实例同时写配置。
- 不全局重启 systemd-networkd，只重载并重新配置目标网卡。
- SSH 仅安装并启用，不改 `sshd_config`，不开放公网端口，不配置端口转发。
- 诊断脚本只读，并遮盖 URI 凭据、密码、Token、PSK、私钥字段。

日志保存在：

```text
/var/log/debian-first-network-kit.log
```

权限为 `0600`，只有 root 可读。

## 从镜像开始安装 Debian

### 1. 下载与校验

只从 Debian 官方页面下载 amd64 netinst 镜像：

- <https://www.debian.org/CD/netinst/>
- 校验说明：<https://www.debian.org/CD/verify>

Windows PowerShell 计算 SHA-256：

```powershell
Get-FileHash .\debian-13.x.x-amd64-netinst.iso -Algorithm SHA256
```

必须与 Debian 官方 `SHA256SUMS` 一致。希望校验发布者身份时，再按官方说明验证 `SHA256SUMS.sign`。

### 2. 制作启动 U 盘

推荐顺序：

1. **Ventoy**：一次安装到 U 盘，以后直接复制 ISO；适合同时保存 Windows、Debian、BIOS 文件和本工具箱。
2. **Rufus**：单镜像、一次性安装最直观。
3. **Linux `dd`**：只推荐熟悉块设备的人；选错目标会覆盖整块磁盘。

Ventoy 启动模式：

- 首选 **Boot in normal mode**。
- Normal 无法启动某个 Linux ISO 时才试 **GRUB2 mode**。
- **Memdisk mode** 不适合 Debian netinst，不要选。
- 进入安装前用 Ventoy 的文件校验功能核对 ISO checksum。

Rufus 建议：

- 分区类型：`GPT`
- 目标系统：`UEFI`
- 文件系统按 Rufus 默认
- 如果 ISO mode 无法启动，再重做并选择 DD mode

不要把 BIOS 文件放进 Debian ISO，也不要为“亮机卡”随意刷 BIOS。能正常识别 CPU、内存、磁盘并进入安装器时，显卡只负责显示，和是否需要更新 BIOS 没有直接关系。

### 3. 安装器怎么选

- `Graphical install`：图形化安装界面。
- `Install`：文字安装界面。

两者安装出的系统没有本质区别；是否安装桌面由最后的“软件选择（tasksel）”决定。服务器新手可以选 `Graphical install`，最后取消桌面即可。

网络暂时不可用时，可以跳过网络镜像，先完成最小系统安装，重启后再运行本工具箱。

### 4. 五种分区方案怎么选

Debian 安装器常见方案：

1. 所有文件放在一个分区。
2. 单独 `/home`。
3. 单独 `/home`、`/var`、`/tmp`。
4. 服务器方案，额外拆分 `/srv`、`/var` 等。
5. 小磁盘方案。

对 N100、小型家用服务器、单块 SSD，推荐：

- `Guided - use entire disk and set up LVM`
- `All files in one partition`

理由是恢复简单、不会因 `/var` 估小导致 Minecraft/容器日志把单独分区撑满。需要高级快照、RAID 或多盘存储时再手动分区。

注意：选择“使用整个磁盘”会清空目标盘，务必按型号和容量确认，不要误选安装 U 盘或数据盘。

### 5. 软件选择

建议勾选：

- `SSH server`
- `standard system utilities`

取消：

- `Debian desktop environment`
- GNOME、KDE、Xfce 等桌面项

`Graphical install` 不会强制安装桌面。已经安装桌面也能卸载，但全新服务器直接不选桌面最干净。

如果安装器允许 root 密码留空，留空后首个普通用户会获得 `sudo` 权限；用户名建议只用小写英文字母和数字。

## 你截图中的 APT/SSH 故障

出现下面几类信息时，不要继续重复运行 `apt update`：

```text
Package 'openssh-server' has no installation candidate
signature verification failed
No such file or directory: debian-archive-keyring.gpg
Temporary failure resolving deb.debian.org
```

分别代表：

- `Temporary failure resolving`：DNS 尚未修好。
- `no installation candidate`：APT 没有可用的软件索引或软件源。
- `keyring/signature`：归档密钥包缺失、`Signed-By` 路径错误或源配置损坏。

本工具按正确顺序处理：

1. 确认网卡有 IPv4 和默认路由。
2. 修复 DNS。
3. 写入与 Debian 版本匹配的官方 deb822 源。
4. 使用这个独立官方源更新索引并安装 `debian-archive-keyring`、证书。
5. 安装并启用 `openssh-server`。

如果系统连 `debian-archive-keyring` 都完全缺失，APT 会拒绝不受信任的软件源——这是正确的安全行为。请从同版本 Debian 官方安装介质恢复 keyring，或重新安装最小系统；不要使用 `--allow-unauthenticated`、不要关闭签名校验。

## 手动确认

```bash
ip -br link
ip -4 -br address
ip route
getent ahosts deb.debian.org
systemctl status ssh --no-pager
ss -lntp | grep ':22'
```

在另一台同局域网电脑：

```bash
ssh <用户名>@<服务器IP>
```

若失败，先运行并保存诊断结果：

```bash
sudo bash scripts/diagnose-network.sh | tee network-report.txt
```

更多说明见 [安装指南](docs/installation-guide.md) 和 [故障排查](docs/troubleshooting.md)。

## 项目文件

```text
scripts/bootstrap-network.sh   自动恢复 DHCP、DNS、APT、SSH
scripts/diagnose-network.sh    只读诊断和隐私遮盖
docs/installation-guide.md     从 ISO 到首次 SSH
docs/troubleshooting.md        常见错误与人工处理
```

许可证：[MIT](LICENSE)
