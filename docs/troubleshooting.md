# 故障排查

## 一输入命令就出现四个菱形

常见原因是终端字体/编码无法显示字符，或者命令仍在等待网络超时。先按 `Ctrl+C`，再切英文：

```bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
```

脚本也可用：

```bash
sudo bash scripts/bootstrap-network.sh --lang en
```

## 网卡是 DOWN

```bash
ip -br link
cat /sys/class/net/enp2s0/carrier
```

- `carrier=0`：网线、扩展坞、SFP 模块、交换机口或协商存在问题。
- `carrier=1` 但没有地址：需要 DHCP/网络管理器配置。
- USB/Type‑C 扩展坞可能在安装器中缺固件；优先用主板原生网口完成首次安装。

## 有地址但不能上网

```bash
ip route
ping -c 3 1.1.1.1
getent ahosts deb.debian.org
```

- 能 ping IP、不能解析域名：DNS 问题。
- 没有 `default via ...`：DHCP 或路由问题。
- 两者都有但外网不通：检查 AX1900/上游路由器的 LAN、网关和防火墙。

## openssh-server 没有安装候选

```bash
apt-cache policy openssh-server
grep -RhsE '^(Types:|URIs:|Suites:|Signed-By:)' \
  /etc/apt/sources.list /etc/apt/sources.list.d
```

先修 DNS，再修 APT。不要反复运行同一条失败的 `apt update`。

## keyring 或签名错误

不要使用以下危险选项：

```text
--allow-unauthenticated
Acquire::AllowInsecureRepositories=true
trusted=yes
```

确认系统版本：

```bash
. /etc/os-release
printf '%s %s %s\n' "$ID" "$VERSION_ID" "$VERSION_CODENAME"
```

正确组合只有：

- Debian 12 + bookworm
- Debian 13 + trixie

如果 `/usr/share/keyrings/debian-archive-keyring.gpg` 缺失，请从同版本官方 Debian 安装介质恢复 `debian-archive-keyring`，或重装最小系统；不要从论坛或网盘下载未知密钥。

## SSH 已启动但连不上

```bash
systemctl status ssh --no-pager
ss -lntp | grep ':22'
ip -4 -br address
```

确认客户端与服务器位于同一局域网，连接的是服务器 LAN 地址，不是 `127.0.0.1`、Docker 地址或 Wi‑Fi 地址。

## 收集诊断

```bash
sudo bash scripts/diagnose-network.sh | tee network-report.txt
```

报告会遮盖常见凭据，但分享前仍应人工检查公网 IP、主机名、内网拓扑等隐私信息。
