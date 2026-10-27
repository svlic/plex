# Plex 服务器工具箱

一个中文交互式 Bash 脚本，主要适配 **Debian 12/13、amd64 / arm64 / ARM 32 位**。其它 Linux 发行版不会被版本检查阻断，但依赖自动安装使用 `apt-get`；无 apt 的系统需自行准备依赖。ttyd 和 SSH 管理需要 systemd，BBR 需要宿主机内核支持与修改 sysctl 的权限。

## 使用

直接复制以下命令，下载脚本并以 root 运行，在菜单中选择要安装或配置的功能（需已安装 `curl`）：

```bash
curl -fSL https://raw.githubusercontent.com/svlic/plex/main/plex.sh -o plex.sh && sudo bash plex.sh
```

如果当前已是 root 用户，将命令中的 `sudo bash plex.sh` 改为 `bash plex.sh` 即可。脚本会保存在当前目录，之后可运行 `sudo bash plex.sh` 再次打开菜单。

菜单：

```text
1. 安装 Docker（官方脚本）
2. Docker 安装/配置 usque（SOCKS5）
3. GitHub 安装/配置 ttyd（Web 终端）
4. 开启 BBR + fq
5. 修改 SSH 端口并生效
0. 退出
```

也可以直接进入某项功能，参数依然交互输入：

```bash
sudo bash plex.sh usque  # docker / usque / ttyd / bbr / ssh
bash plex.sh --help
```

脚本可以连续执行多项功能；单项失败会返回菜单，不会继续执行该项后续步骤。用户名、密码、监听端口均可配置；密码输入隐藏且需二次确认。用户名允许 1–64 个字母、数字、下划线、短横线；密码允许 8–128 个 ASCII 可打印字符，支持空格和特殊符号，端口范围为 1–65535。

## 功能与注意事项

### 1. Docker

下载并执行 [Docker 官方安装脚本](https://get.docker.com)，在 systemd 可用时启用开机启动。检测到已有 Docker 会跳过，**不会用官方安装脚本升级现有安装**，也不会自动给普通用户授予 docker 组权限。官方脚本是否支持当前发行版由 Docker 决定。

### 2. usque

使用 [Diniboy1123/usque](https://github.com/Diniboy1123/usque) 最新稳定 Release 的源码及其官方 Dockerfile，在本机构建 `plex-usque:<版本>` 镜像。不依赖未经核实的第三方镜像；首次构建需要网络和一定的磁盘、内存，ARM 平台由官方 Dockerfile 的基础镜像支持情况决定。

- 需要先安装并启动 Docker。
- 自动注册 WARP，配置持久保存在 `/var/lib/plex/usque/config.json`（root-only）。注册失败不启动代理。
- 使用 SOCKS5 用户名/密码认证，容器名称 `plex-usque`，配置只读挂载，重启策略 `unless-stopped`。
- **自定义端口是宿主机端口**：例如输入 `21080`，Docker 将宿主机 `21080` 的 TCP/UDP 映射至容器内固定的 `1080`。客户端连接 `服务器地址:21080`（远程访问需选择监听 `0.0.0.0`）。
- **代理流量出口走 WARP**：客户端 → 宿主机自定义端口 → 容器 usque SOCKS5 → WARP 隧道 → 目标网站。不修改宿主机默认路由，不接管未使用 SOCKS5 的其它流量。
- 默认仅监听 `127.0.0.1`，可选择监听 `0.0.0.0`。SOCKS5 UDP ASSOCIATE 的公网可达性还取决于 Docker NAT、服务返回的中继地址和客户端，不保证所有 NAT 场景均可用。
- 再次执行可更新版本、认证与端口，保留 WARP 配置。新容器启动失败会尝试恢复旧容器；不覆盖同名的非本脚本管理容器。
- 启动检查只证明进程存活，**不证明 WARP 出口可用**。请用 SOCKS5 客户端验证代理流量。

```bash
docker logs --tail 100 plex-usque
docker restart plex-usque
```

SOCKS5 认证不是加密传输；本机 root 和 Docker 管理员可读取容器参数中的认证信息。公网部署需限制来源 IP，必要时使用安全隧道。Docker 发布端口可能绕过部分 UFW 规则，请检查 Docker 防火墙链和云安全组。使用 WARP 应遵守服务条款与当地法律。

### 3. ttyd

从 [tsl0922/ttyd GitHub Releases](https://github.com/tsl0922/ttyd/releases) 解析最新稳定版，按 CPU 选择 `x86_64`、`aarch64`、`armhf` 或 `arm`，下载后对照同版 `SHA256SUMS` 校验，再安装为 `/usr/local/bin/plex-ttyd`。校验用于检查资源完整性，不替代发布方签名或信任审计。

- 配置用户名/密码为 **HTTP Basic 认证账号，不是 Linux 登录账号**。
- 终端直接以 **root** 执行 `/bin/bash -l`，工作目录 `/root`，可管理系统；不再创建专用的非 root 用户，也不限制终端对系统目录的访问。
- 默认仅监听 `127.0.0.1:7681`，可自定义端口并选择 `0.0.0.0`；认证信息位于 `/etc/plex/ttyd.env`，权限 `600`。本机 root 仍能读取进程认证参数。
- systemd 服务 `plex-ttyd.service` 自动启动，启用可写终端和同源检查。重复执行会覆盖本脚本的配置并重启服务；旧版创建的非 root 账号和数据不会自动删除。
- **Web 密码泄露等于服务器 root 权限泄露，HTTP Basic 认证不提供加密。** 请通过 SSH 隧道或 HTTPS 反向代理访问，并限制来源 IP，不要裸露在公网。

```bash
systemctl status plex-ttyd
journalctl -u plex-ttyd -e
systemctl restart plex-ttyd
```

在自己的电脑建立隧道后，浏览器访问 `http://127.0.0.1:7681`：

```bash
ssh -N -L 7681:127.0.0.1:7681 用户名@服务器地址
```

### 4. BBR + fq

尝试加载 `tcp_bbr` / `sch_fq`，检查 BBR 是否可用，然后修改当前 sysctl 并写入 `/etc/sysctl.d/99-plex-bbr.conf`。内核拒绝修改时尝试恢复原值，不写入新的持久配置；不支持 BBR 时不会替换内核或要求重启。

`net.core.default_qdisc=fq` 设置默认队列规则，不强制重建已有网卡队列，避免远程断网。已有网卡是否使用 fq 可通过 `tc qdisc show` 查看；其它 sysctl 文件若覆盖同名参数，重启后的最终值仍需检查。

### 5. SSH 端口

修改 `/etc/ssh/sshd_config` 和标准 `/etc/ssh/sshd_config.d/*.conf` 中的活动 `Port` 指令，保留其它配置与 `Match` 块。操作前备份到 `/var/backups/plex/ssh-时间戳-进程号/`，执行 `sshd -t`、检查 `sshd -T` 的端口/监听地址后才应用。

- 支持 `ssh.service` / `sshd.service`；检测到 Debian 的 `ssh.socket` 时同步写入 `/etc/systemd/system/ssh.socket.d/plex.conf` 并重启相关单元。
- 检查新端口是否有监听；验证或应用失败时尝试恢复原配置与服务。恢复失败仍需通过保留会话或控制台手工救援。
- 非标准 Include 中仍有旧 Port、显式带旧端口的 ListenAddress 等冲突会导致检查失败并回滚，而不是报告虚假的成功。自定义 SSH 服务命令行端口覆盖、非标准 socket 名称及复杂 systemd 覆盖不保证兼容，需手工检查。
- **不自动修改防火墙、安全组、SELinux 或 SSH 认证方式。** 请先放行新 TCP 端口，保留当前 SSH 会话与控制台救援入口，另开连接确认成功后再关闭旧会话。

## 验证

测试仅在临时 Docker 容器中运行，不挂载宿主机 Docker socket，也不改宿主机 SSH/sysctl：

```bash
docker build --build-arg DEBIAN_VERSION=12 -t plex-test:12 -f tests/Dockerfile .
docker run --rm -v "$PWD:/src:ro" plex-test:12
docker build --build-arg DEBIAN_VERSION=13 -t plex-test:13 -f tests/Dockerfile .
docker run --rm -v "$PWD:/src:ro" plex-test:13
```

覆盖 ShellCheck、输入校验、真实 sshd 端口切换及失败回滚、socket 配置生成、GitHub ttyd 下载与校验、真实 HTTP 认证与重配置、BBR 权限失败、Docker 编排和旧容器恢复。容器中 systemctl、sysctl 和 Docker 控制面使用替身，因此不等同于完整虚拟机中的 systemd/socket、BBR 内核或 WARP 出口验证。全新 Docker 官方安装也需在可丢弃的 VM 中验证，避免改变已有 Docker 环境。
