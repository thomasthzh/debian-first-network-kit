# Debian First Network Kit 设计规格

日期：2026-07-29
状态：已获用户批准，等待规格复核
目标仓库：`debian-first-network-kit`（公开、MIT）

## 1. 背景与目标

Debian 12/13 在离线安装、安装器未识别网络、未选择 SSH 任务或 APT 仅保留安装介质源时，首次启动可能同时出现以下问题：

- 有线网卡存在但处于 `DOWN`；
- 网卡已经 `UP`，却没有 DHCP 地址；
- 已获得 IPv4 地址和默认路由，但 DNS 解析失败；
- `apt update` 没有有效在线仓库；
- `openssh-server` 显示“没有安装候选”；
- SSH 服务不存在，无法从另一台电脑接管。

本项目提供一套可从 U 盘离线携带的恢复工具和中文教程，使用户能在本地控制台完成首次联网，并尽快通过 SSH 转入远程管理。

成功标准：

1. 在 Debian 12 或 Debian 13 的最小化安装环境中，仅依赖 Bash、iproute2、systemd 和基础 GNU 工具即可运行核心恢复流程。
2. 自动或交互式选定正确的有线接口，启用链路并取得 DHCP IPv4 地址。
3. 能区分物理链路、DHCP、路由、DNS、APT 和 SSH 六层问题，并给出明确结果。
4. 默认恢复 Debian 官方软件源、安装并启动 OpenSSH；用户可以通过参数跳过。
5. 所有持久配置写入前均备份，不覆盖无关第三方源，不记录密码或其他秘密。
6. 同一脚本可以重复执行；已完成的步骤应安全跳过或刷新，不不断追加重复配置。

## 2. 支持范围

### 2.1 支持

- Debian 12（bookworm）和 Debian 13（trixie）；
- amd64 裸机、迷你主机、家用服务器和常见虚拟机；
- 单个或多个有线接口；
- NetworkManager、systemd-networkd，以及未正确配置的 ifupdown 场景；
- DHCP IPv4；
- 通过普通 U 盘、Ventoy 数据分区或本地文件运行。

### 2.2 非目标

- 不支持自动配置 Wi-Fi、PPPoE、802.1X、VLAN、网桥、Bond、静态公网地址或旁路由；
- 不修改路由器、防火墙、端口转发或校园网认证设置；
- 不自动卸载桌面环境；
- 不替代完整的服务器加固、密钥轮换或备份方案；
- 不声称支持 Debian 以外的发行版。

遇到非目标场景时，脚本应停止自动修改，输出诊断信息和人工处理建议。

## 3. 方案选择

采用“单入口恢复脚本 + 独立只读诊断脚本 + 分层教程”的结构。

未采用的替代方案：

- 单个巨型脚本：携带方便，但诊断和修改耦合，难以安全复用；
- Ansible/cloud-init：适合批量部署，但首次离线状态下通常不可用；
- 仅提供命令清单：最透明，但容易因手工输入路径、网卡名或软件源字段而出错。

推荐结构兼顾离线可用、可审计和初学者操作成本。

## 4. 仓库结构

```text
debian-first-network-kit/
├── README.md
├── LICENSE
├── CHANGELOG.md
├── scripts/
│   ├── bootstrap-network.sh
│   └── diagnose-network.sh
├── docs/
│   ├── installation-guide.md
│   ├── troubleshooting.md
│   └── superpowers/specs/
│       └── 2026-07-29-debian-first-network-kit-design.md
└── tests/
    └── smoke-test.sh
```

USB 上复制完整目录，而不是仅复制脚本，以便离线查看教程。

## 5. `bootstrap-network.sh` 设计

### 5.1 命令行接口

```text
sudo bash bootstrap-network.sh [选项]

--interface IFACE  指定有线接口
--dns ADDR         追加一个后备 DNS，可重复
--no-apt           不写入官方 APT 源、不运行 apt update
--no-ssh           不安装和启动 OpenSSH
--yes              对计划内修改自动确认
--help             显示帮助
```

默认行为是恢复网络、DNS 和官方软件源，并安装 SSH。

### 5.2 启动检查

1. 要求 root；非 root 时给出 `sudo bash ...` 示例。
2. 读取 `/etc/os-release`，仅接受 Debian 12/13。
3. 创建日志 `/var/log/debian-first-network-kit.log`；日志不包含密码、令牌或环境变量值。
4. 显示将要修改的文件和服务，并在非 `--yes` 模式下请求确认。

### 5.3 接口发现

候选接口来自 `/sys/class/net`，并满足：

- 排除 `lo`、无线接口、桥、Bond、VLAN、隧道、容器虚拟接口；
- 具有 `/sys/class/net/<iface>/device` 或明确的 Ethernet 类型；
- 优先选择已经具有 `carrier=1` 的接口。

选择规则：

- `--interface` 存在时验证后直接使用；
- 只有一个候选时使用该接口；
- 多个候选且仅一个有物理链路时选择该接口；
- 多个候选仍有歧义时，交互模式列出接口、MAC、carrier 和当前地址；
- `--yes` 模式遇到歧义必须失败，不能随机选择。

脚本先执行 `ip link set IFACE up`，再等待 carrier。没有 `LOWER_UP` 时停止网络修改，并提示检查 LAN/WAN 端口、网线、扩展坞供电和驱动。

### 5.4 DHCP 管理策略

如果接口已经具有非链路本地 IPv4 地址和默认路由，跳过 DHCP 配置。

否则按以下顺序处理：

1. NetworkManager 正在运行且 `nmcli` 可用：请求 NetworkManager 管理并连接接口；
2. systemd-networkd 正在运行：写入项目专用 `.network` 文件并重新配置；
3. ifupdown 已为接口配置 DHCP：尝试 `ifup`；
4. 其余情况：启用 systemd-networkd，写入
   `/etc/systemd/network/20-debian-first-network-IFACE.network`。

项目专用 networkd 文件内容为接口精确匹配和 `DHCP=yes`。写入前备份同名文件；不删除其他管理器配置。若检测到两个管理器会竞争同一接口，脚本停止并解释冲突。

脚本等待 DHCP 地址和默认路由，超时后输出 `networkctl status`、地址、路由和日志摘要。

### 5.5 DNS 恢复

检查顺序：

1. 是否存在默认路由；
2. 是否能访问默认网关；
3. 是否能访问一个纯 IP 测试目标；
4. `getent ahosts deb.debian.org` 是否成功。

DNS 正常时不修改配置。

DNS 失败时：

- 备份 `/etc/resolv.conf`，包括记录其原始符号链接目标；
- 优先使用 DHCP 网关作为第一 DNS；
- 后备 DNS 默认为 `1.1.1.1` 和 `9.9.9.9`，允许用 `--dns` 追加；
- 生成最小化的 `/etc/resolv.conf`，再次验证解析；
- 如果 public DNS 被网络阻断但网关 DNS 可用，只保留可用项。

脚本不会删除原备份。教程说明静态 `resolv.conf` 是恢复手段；进入远程管理后可再切换到 NetworkManager 或 systemd-resolved 的完整动态方案。

### 5.6 Debian 官方软件源

根据 `VERSION_CODENAME` 生成项目专用源文件：

`/etc/apt/sources.list.d/debian-first-network-kit.sources`

内容包括：

- `deb.debian.org/debian` 的发行版与 `-updates`；
- `security.debian.org/debian-security` 的 `-security`；
- `main contrib non-free non-free-firmware`；
- 仅在 `/usr/share/keyrings/debian-archive-keyring.gpg` 确实存在时写入 `Signed-By`。

脚本不覆盖第三方源。对 `deb cdrom:` 条目只做提示；若它阻止更新，经过确认后在备份文件中注释。

运行 `apt-get update` 前再次验证 DNS。失败时保留完整错误并给出下一步，不继续安装 SSH。

### 5.7 SSH 安装

在 APT 更新成功后：

1. 安装 `openssh-server`；
2. `systemctl enable --now ssh`；
3. 验证服务为 active；
4. 输出接口 IPv4、端口 22 监听状态和示例连接命令。

脚本不启用 root 密码登录、不写入用户密码、不修改 `sshd_config` 的安全默认值。密钥登录和进一步加固留给后续管理。

## 6. `diagnose-network.sh` 设计

诊断脚本只读运行，可由普通用户执行；需要读取系统日志的部分在有 sudo 时增强。

输出分区：

- 系统版本和内核；
- 接口状态、MAC、carrier、驱动；
- IPv4/IPv6 地址；
- 路由和默认网关；
- DNS 配置与解析测试；
- NetworkManager/networkd/ifupdown 状态；
- APT 有效源和 `openssh-server` 候选版本；
- SSH 服务及监听端口；
- 最近的链路、DHCP、DNS 和 ACPI 网络相关日志。

输出不得包含密码、私钥、GitHub 令牌、Wi-Fi PSK 或完整环境变量。

## 7. 教程设计

### 7.1 镜像与启动盘

教程包含：

- 从 Debian 官方 stable amd64 netinst 页面下载；
- 用官方 SHA256/SHA512 文件验证镜像；
- Ventoy、Rufus 和直接写盘三种方式：
  - Ventoy：适合一个 U 盘保存多个 ISO，首次安装 Ventoy 会清盘，之后只需复制 ISO；
  - Rufus：适合单镜像和最简单的图形界面流程，但写入会覆盖目标 U 盘；
  - `dd`/直接写盘：Linux 下依赖最少，但选错设备会造成数据损失。
- Ventoy 二级启动菜单：
  - Normal：默认首选；
  - GRUB2：Normal 启动 Linux ISO 失败时尝试；
  - Memdisk：仅适合较小且启动后无需继续挂载 ISO 的镜像，Debian netinst 不作为首选；
  - File checksum：复制完成后验证文件，避免缓存未写完或介质损坏。
- 推荐 UEFI 启动；官方 Debian 支持 Secure Boot。Ventoy 首次 Secure Boot 启动可能需要登记密钥，遇到问题可临时关闭。

### 7.2 Debian 安装选择

- `Graphical install` 与 `Install` 仅是安装器界面不同，不决定最终是否安装桌面；
- 服务器建议使用英文安装界面，系统 locale 可按需选择；
- 优先接有线网络；网络失败可以继续离线安装；
- 五种引导分区方案：
  1. 全部文件放在一个分区；
  2. 单独 `/home`；
  3. 单独 `/home`、`/var`、`/tmp`；
  4. 服务器方案：单独 `/srv`、`/var`，swap 上限 1GB；
  5. 小硬盘方案。
- 普通单盘家用服务器推荐“全部文件放在一个分区”，维护最简单；明确需要隔离服务数据时才选服务器方案。
- 软件选择推荐：
  - 取消 Debian desktop environment 及所有桌面；
  - 勾选 SSH server；
  - 保留 Standard system utilities；
  - 不因选择 Graphical install 而误判会安装桌面。

### 7.3 首次启动与 U 盘运行

教程给出：

1. 本地显示器和键盘登录；
2. `lsblk -f` 确认 U 盘分区；
3. 创建挂载点并只挂载正确分区；
4. 执行诊断脚本；
5. 执行恢复脚本；
6. 从另一台机器 SSH 登录；
7. 安全弹出 U 盘。

不得提供固定设备名示例后让用户无确认直接写盘；涉及 `/dev/sdX` 的操作必须强调先用容量、型号和序列号核对。

## 8. 故障排查映射

| 症状 | 判定 | 处理 |
|---|---|---|
| 接口 `DOWN` | 管理状态未启用 | `ip link set ... up` 或运行恢复脚本 |
| `UP` 但无 `LOWER_UP` | 无物理 carrier | 检查线缆、端口、扩展坞、驱动 |
| 有 `LOWER_UP` 但无地址 | DHCP/管理器未配置 | 交由 NetworkManager 或 networkd |
| 有地址无默认路由 | DHCP 不完整或静态配置错误 | 重新申请 DHCP并检查路由 |
| 能 ping IP，不能解析域名 | DNS 故障 | 备份并恢复 resolver |
| `apt update` 立即结束且无下载 | 仅 CD-ROM 源或无在线源 | 写入 Debian 官方源 |
| 软件包“没有安装候选” | 索引或组件缺失 | 修复源并重新 update |
| `ssh.service does not exist` | 未安装 openssh-server | 联网后安装并启用 |
| ACPI BIOS Error 但系统继续运行 | 常见固件警告 | 与联网问题分开诊断 |

## 9. 安全与隐私

- 仓库公开，但不包含真实账号、密码、令牌、内网 IP、MAC、主机名、路由器配置或现场截图；
- 示例统一使用文档地址和占位名称；
- 不在脚本中使用 `curl | sh`；
- 所有下载指向 Debian、Ventoy、Rufus 等官方页面；
- 文件修改先备份，备份名包含 UTC 时间戳；
- 不自动修改 SSH root 登录、用户密码、防火墙或路由器；
- 日志对敏感路径和命令参数保持克制。

## 10. 验证计划

本地验证：

- `bash -n` 检查所有 Shell 文件；
- 若存在 ShellCheck，则执行 ShellCheck；
- `tests/smoke-test.sh` 验证帮助、非法参数、非 Debian 拒绝、候选接口选择和配置渲染；
- 搜索仓库中是否意外出现本次真实凭据、地址、主机名或临时文件；
- 检查 Markdown 链接和代码块。

安全验证：

- 在模拟目录中验证备份和幂等写入；
- 不在当前 Windows 主机或真实路由器上运行 Linux 修改路径；
- U 盘复制后逐文件计算 SHA256，与本地项目比较。

发布验证：

- Git 工作树仅包含项目目录；
- 创建 public GitHub 仓库并推送 `main`；
- 从远端读取仓库元数据和文件列表确认；
- U 盘目标固定为已确认的 Kingston 主数据分区，不触碰 BIOS 分区和现有 ISO。

## 11. 交付

最终交付物：

1. 本地 Git 仓库；
2. 金士顿 U 盘中的完整项目副本；
3. GitHub public 仓库 URL；
4. 验证摘要，包括脚本语法、测试、USB 哈希比对和远端推送结果。
