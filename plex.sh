#!/usr/bin/env bash
# Debian 12/13 first; other Linux distributions are not blocked.
set -Eeuo pipefail
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

info() { printf '\n%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
confirm() {
    local answer
    read -r -p "$* [y/N]: " answer || die '输入已结束，取消操作。'
    [[ "$answer" == y || "$answer" == Y ]]
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
ask_port() {
    local input
    while true; do
        read -r -p "监听端口 [$1]: " input || die '输入已结束。'
        input=${input:-$1}
        if valid_port "$input"; then PORT=$((10#$input)); return; fi
        info '端口必须为 1–65535 的整数。'
    done
}

ask_credentials() {
    while true; do
        read -r -p '认证用户名 [admin]（字母、数字、_、-）: ' USERNAME || die '输入已结束。'
        USERNAME=${USERNAME:-admin}
        [[ "$USERNAME" =~ ^[a-zA-Z0-9_-]{1,64}$ ]] && break
        info '用户名格式不正确。'
    done
    local again
    while true; do
        read -r -s -p '认证密码（8–128 个 ASCII 可打印字符）: ' PASSWORD || die '输入已结束。'
        printf '\n'
        if ! LC_ALL=C grep -Eq '^[ -~]{8,128}$' <<< "$PASSWORD"; then
            info '密码长度或字符不符合要求。'; continue
        fi
        read -r -s -p '再次输入密码: ' again || die '输入已结束。'
        printf '\n'
        [[ "$PASSWORD" == "$again" ]] && break
        info '两次密码不一致。'
    done
}

ask_bind() {
    BIND=127.0.0.1
    info '默认仅监听 127.0.0.1。公网使用请限制来源 IP；ttyd 还应配置 HTTPS 反向代理。'
    if confirm '改为监听 0.0.0.0，允许远程访问？'; then BIND=0.0.0.0; fi
}

ensure_tools() {
    local spec command package
    local -a packages=()
    for spec in "$@"; do
        command=${spec%%:*}; package=${spec#*:}
        command -v "$command" >/dev/null || packages+=("$package")
    done
    if ((${#packages[@]})); then
        command -v apt-get >/dev/null || die "请先通过系统包管理器安装：${packages[*]}，然后重试。"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" ca-certificates
    fi
}

download() { curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 600 "$1" -o "$2"; }
require_systemd() {
    command -v systemctl >/dev/null || die '此功能需要 systemd。'
    systemctl show-environment >/dev/null || die 'systemd 当前不可用。'
}
require_docker() {
    command -v docker >/dev/null || die '请先选择菜单 1 安装 Docker。'
    docker info >/dev/null || die 'Docker 守护进程不可用，请先启动 Docker。'
}
port_free() {
    if [[ -n "$(ss -H -ltn "sport = :$1")" ]]; then die "TCP 端口 $1 已被占用。"; fi
}

install_docker() {
    ensure_tools curl:curl
    if command -v docker >/dev/null; then
        docker --version
        info '已存在 Docker，官方脚本不适合直接升级现有安装；未重复安装。'
        return
    fi
    info '将下载并执行 https://get.docker.com 官方安装脚本。'
    confirm '继续安装 Docker？' || return 0
    download https://get.docker.com "$TMP/docker-install.sh"
    sh "$TMP/docker-install.sh"
    if command -v systemctl >/dev/null && systemctl show-environment >/dev/null 2>&1; then
        systemctl enable --now docker
    fi
    docker version
    info 'Docker 安装完成。未将任何用户加入具有 root 等价权限的 docker 组。'
}

install_usque() {
    require_docker
    ensure_tools curl:curl python3:python3 tar:tar ss:iproute2
    ask_credentials
    info '下面设置宿主机的 SOCKS5 端口；容器内固定监听 1080，代理出口走 WARP。'
    ask_port 1080
    ask_bind
    local image tag old=''
    if docker container inspect plex-usque >/dev/null 2>&1; then
        [[ "$(docker inspect -f '{{index .Config.Labels "io.plex.managed"}}' plex-usque)" == true ]] || die '同名容器不由本脚本管理，拒绝覆盖。'
        confirm '已有 plex-usque 容器，替换它并保留 WARP 注册数据？' || return 0
        old="plex-usque-backup-$(date +%s)-$$"
    else
        port_free "$PORT"
        [[ -z "$(ss -H -lun "sport = :$PORT")" ]] || die "UDP 端口 $PORT 已被占用。"
    fi
    download https://api.github.com/repos/Diniboy1123/usque/releases/latest "$TMP/release.json"
    tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$TMP/release.json")
    [[ "$tag" =~ ^v?[0-9][a-zA-Z0-9._-]*$ ]] || die '无效的 usque 发布版本。'
    image="plex-usque:$tag"
    info "从官方源码构建 $image，首次构建可能需要数分钟。"
    download "https://github.com/Diniboy1123/usque/archive/refs/tags/$tag.tar.gz" "$TMP/usque.tar.gz"
    mkdir "$TMP/source"
    tar -xzf "$TMP/usque.tar.gz" --strip-components=1 -C "$TMP/source"
    docker build --pull -t "$image" "$TMP/source"
    install -d -m 700 /var/lib/plex/usque
    if [[ ! -s /var/lib/plex/usque/config.json ]]; then
        docker run --rm -v /var/lib/plex/usque:/config "$image" -c /config/config.json register
        [[ -s /var/lib/plex/usque/config.json ]] || die 'WARP 注册未生成配置，请检查网络或稍后重试。'
    fi
    chmod 600 /var/lib/plex/usque/config.json
    if [[ -n "$old" ]]; then
        docker rename plex-usque "$old"
    fi
    # Keep the previous container until the new process has survived startup.
    trap 'rc=$?; trap - ERR; docker rm -f plex-usque >/dev/null 2>&1 || true;
        if [[ -n "$old" ]]; then docker rename "$old" plex-usque; docker start plex-usque; fi;
        exit "$rc"' ERR
    if [[ -n "$old" ]]; then docker stop "$old"; fi
    docker run -d --name plex-usque --restart unless-stopped \
        --label io.plex.managed=true \
        -p "$BIND:$PORT:1080/tcp" -p "$BIND:$PORT:1080/udp" \
        -v /var/lib/plex/usque:/config:ro \
        "$image" -c /config/config.json socks -b 0.0.0.0 -p 1080 -u "$USERNAME" -w "$PASSWORD"
    sleep 3
    [[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' plex-usque)" == 'true 0' ]]
    trap 'printf "执行失败（第 %s 行）。\n" "$LINENO" >&2' ERR
    if [[ -n "$old" ]]; then docker rm "$old" >/dev/null; fi
    info "usque 已启动：宿主机 SOCKS5 $BIND:$PORT → 容器 1080 → WARP，用户名 $USERNAME。"
    info '进程存活不代表 WARP 已连通；请使用 SOCKS5 客户端验证出口。日志：docker logs plex-usque'
    info '认证信息可被本机 root / Docker 管理员读取；SOCKS5 认证不加密，请勿直接暴露给不可信网络。'
}

env_quote() {
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

install_ttyd() {
    require_systemd
    ensure_tools curl:curl python3:python3 sha256sum:coreutils ss:iproute2
    local arch binary url sums
    case "$(uname -m)" in
        x86_64|amd64) arch=x86_64 ;;
        aarch64|arm64) arch=aarch64 ;;
        armv7*|armv6*) arch=armhf ;;
        armv5*) arch=arm ;;
        *) die 'GitHub 预编译包未适配此架构，请自行编译 ttyd。' ;;
    esac
    info '警告：ttyd 将直接提供 root 终端，获得 Web 认证密码即拥有服务器 root 权限。请使用 SSH 隧道或 HTTPS 并限制来源 IP。'
    ask_credentials
    ask_port 7681
    ask_bind
    if [[ -f /etc/systemd/system/plex-ttyd.service ]]; then
        confirm '覆盖现有 plex-ttyd 配置并重启？' || return 0
    else
        port_free "$PORT"
    fi
    binary="ttyd.$arch"
    download https://api.github.com/repos/tsl0922/ttyd/releases/latest "$TMP/release.json"
    python3 - "$TMP/release.json" "$binary" > "$TMP/urls" <<'PY'
import json, sys
assets = {a['name']: a['browser_download_url'] for a in json.load(open(sys.argv[1]))['assets']}
for name in (sys.argv[2], 'SHA256SUMS'):
    url = assets[name]
    if not url.startswith('https://github.com/tsl0922/ttyd/releases/download/'):
        raise SystemExit('非官方 ttyd 资源地址')
    print(url)
PY
    { read -r url; read -r sums; } < "$TMP/urls"
    download "$url" "$TMP/$binary"
    download "$sums" "$TMP/SHA256SUMS"
    python3 - "$TMP/SHA256SUMS" "$binary" > "$TMP/checksum" <<'PY'
import re, sys
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) == 2 and parts[1].lstrip('*') == sys.argv[2] and re.fullmatch('[0-9a-fA-F]{64}', parts[0]):
        print(parts[0] + '  ' + sys.argv[2])
        break
else:
    raise SystemExit('SHA256SUMS 中找不到对应二进制')
PY
    (cd "$TMP" && sha256sum -c checksum)
    chmod 755 "$TMP/$binary"
    "$TMP/$binary" --version
    install -m 755 "$TMP/$binary" /usr/local/bin/plex-ttyd
    install -d -m 700 /etc/plex
    {
        printf 'TTYD_CREDENTIAL='; env_quote "$USERNAME:$PASSWORD"; printf '\n'
        printf 'TTYD_PORT=%s\nTTYD_BIND=%s\n' "$PORT" "$BIND"
    } > /etc/plex/ttyd.env
    chmod 600 /etc/plex/ttyd.env
    cat > /etc/systemd/system/plex-ttyd.service <<'UNIT'
[Unit]
Description=Plex ttyd web terminal
After=network.target

[Service]
User=root
Group=root
WorkingDirectory=/root
EnvironmentFile=/etc/plex/ttyd.env
ExecStart=/usr/local/bin/plex-ttyd -i ${TTYD_BIND} -p ${TTYD_PORT} -c ${TTYD_CREDENTIAL} -W -O /bin/bash -l
Restart=on-failure
RestartSec=3
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable plex-ttyd.service
    systemctl restart plex-ttyd.service
    sleep 2
    systemctl is-active --quiet plex-ttyd.service
    [[ -n "$(ss -H -ltn "sport = :$PORT")" ]]
    info "ttyd 已启动：http://$BIND:$PORT，认证用户名 $USERNAME。终端系统用户为 root，工作目录 /root。"
    info '密码不回显；通过 SSH 隧道或 HTTPS 反向代理访问。日志：journalctl -u plex-ttyd -e'
}

enable_bbr() {
    ensure_tools sysctl:procps
    command -v modprobe >/dev/null && { modprobe tcp_bbr || true; modprobe sch_fq || true; }
    local available old_cc old_qdisc
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
    [[ " $available " == *' bbr '* ]] || die '当前内核不支持 BBR；未修改持久配置。请先升级宿主机内核。'
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    old_qdisc=$(sysctl -n net.core.default_qdisc)
    if ! sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr; then
        sysctl -w "net.core.default_qdisc=$old_qdisc" "net.ipv4.tcp_congestion_control=$old_cc" || true
        die '内核拒绝修改（容器可能无此权限），未保存配置。'
    fi
    install -d -m 755 /etc/sysctl.d
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > /etc/sysctl.d/99-plex-bbr.conf
    chmod 644 /etc/sysctl.d/99-plex-bbr.conf
    sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control
    info 'BBR + fq 已启用并持久化。默认 qdisc 针对新建队列生效；未重建现有网卡队列以避免中断网络。'
}

change_ssh_port() {
    require_systemd
    ensure_tools sshd:openssh-server ss:iproute2 python3:python3
    [[ -f /etc/ssh/sshd_config ]] || die '未找到 /etc/ssh/sshd_config。'
    local service=ssh.service socket=false backup file relative
    if ! systemctl cat "$service" >/dev/null 2>&1; then service=sshd.service; fi
    systemctl cat "$service" >/dev/null || die '未找到 SSH systemd 服务。'
    sshd -t
    info "当前 SSH 端口：$(sshd -T | awk '$1 == "port" {printf "%s ", $2}')"
    ask_port 22
    if [[ "$(sshd -T | awk '$1 == "port" {print $2}')" == "$PORT" && -n "$(ss -H -ltn "sport = :$PORT")" ]]; then
        info '配置已为该端口且存在监听，未修改。'; return
    fi
    port_free "$PORT"
    info '请先放行云安全组、系统防火墙的新 TCP 端口，并保留当前 SSH 会话和控制台救援入口。'
    info '脚本不自动修改防火墙。自定义 ListenAddress/Include 或服务启动参数可能需要手工处理。'
    confirm "已放行 TCP $PORT，确认替换原有 SSH 端口？" || return 0
    if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then socket=true; fi
    backup="/var/backups/plex/ssh-$(date +%Y%m%d-%H%M%S)-$$"
    install -d -m 700 "$backup"
    local -a files=(/etc/ssh/sshd_config)
    shopt -s nullglob
    files+=(/etc/ssh/sshd_config.d/*.conf)
    shopt -u nullglob
    local socket_conf=/etc/systemd/system/ssh.socket.d/plex.conf
    [[ ! -e "$socket_conf" ]] || files+=("$socket_conf")
    for file in "${files[@]}"; do
        relative=${file#/}
        mkdir -p "$backup/$(dirname "$relative")"
        cp -pL "$file" "$backup/$relative"
    done
    # Invoked by the ERR trap, not by a direct call.
    # shellcheck disable=SC2317
    rollback_ssh() {
        local rc=$?
        trap - ERR
        for file in "${files[@]}"; do cp -p "$backup/${file#/}" "$file"; done
        if [[ ! -f "$backup/${socket_conf#/}" ]]; then rm -f "$socket_conf"; fi
        systemctl daemon-reload || true
        if "$socket"; then systemctl restart ssh.socket || true; fi
        systemctl restart "$service" || true
        printf 'SSH 修改失败，已尝试恢复原配置。备份：%s。请保留当前会话检查服务。\n' "$backup" >&2
        exit "$rc"
    }
    trap rollback_ssh ERR
    python3 - "$PORT" "${files[@]}" <<'PY'
import pathlib, re, sys
for name in sys.argv[2:]:
    if name.startswith('/etc/ssh/'):
        path = pathlib.Path(name)
        text = re.sub(r'(?im)^([ \t]*Port(?:[ \t]+|=)[^\n]*)$', r'# plex disabled: \1', path.read_text())
        if name == '/etc/ssh/sshd_config':
            text = 'Port ' + sys.argv[1] + '\n' + text
        path.write_text(text)
PY
    sshd -t
    # Port is additive in OpenSSH; detect unhandled Includes and explicit ListenAddress ports.
    sshd -T > "$TMP/sshd-effective"
    [[ "$(awk '$1 == "port" {print $2}' "$TMP/sshd-effective")" == "$PORT" ]]
    awk -v port="$PORT" '$1 == "listenaddress" {n=split($2,a,":"); if(a[n] != port) exit 1}' "$TMP/sshd-effective"
    if "$socket"; then
        install -d -m 755 "$(dirname "$socket_conf")"
        printf '[Socket]\nListenStream=\nListenStream=%s\n' "$PORT" > "$socket_conf"
        chmod 644 "$socket_conf"
    fi
    systemctl daemon-reload
    if "$socket"; then
        systemctl restart ssh.socket
        systemctl restart "$service"
    else
        systemctl reload-or-restart "$service"
    fi
    sleep 2
    [[ -n "$(ss -H -ltn "sport = :$PORT")" ]]
    trap 'printf "执行失败（第 %s 行）。\n" "$LINENO" >&2' ERR
    info "SSH 已监听 TCP $PORT。配置备份：$backup"
    info "请另开终端执行 ssh -p $PORT 用户名@服务器地址，确认成功后再关闭当前连接。外网可达性仍取决于防火墙/安全组。"
}

run_action() (
    set -Eeuo pipefail
    [[ $EUID == 0 ]] || die '请以 root 运行（sudo bash plex.sh）。'
    TMP=$(mktemp -d)
    trap 'rm -rf -- "$TMP"' EXIT
    trap 'printf "执行失败（第 %s 行），请检查上方错误。\n" "$LINENO" >&2' ERR
    case "$1" in
        1|docker) install_docker ;;
        2|usque) install_usque ;;
        3|ttyd) install_ttyd ;;
        4|bbr) enable_bbr ;;
        5|ssh) change_ssh_port ;;
        *) die '未知功能。' ;;
    esac
)

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        printf '用法：bash plex.sh [docker|usque|ttyd|bbr|ssh]\n不指定参数时显示中文菜单；所有配置均交互输入。\n'
        return
    fi
    [[ $(uname -s) == Linux ]] || die '仅支持 Linux。'
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        info "系统：${PRETTY_NAME:-未知}，架构：$(uname -m)"
        if [[ ${ID:-} != debian || ! ${VERSION_ID:-} =~ ^(12|13)$ ]]; then
            info '提示：主要适配 Debian 12/13，其它系统仍可尝试；功能会分别检测依赖。'
        fi
    fi
    if (($#)); then run_action "$1"; return; fi
    local choice rc
    while true; do
        printf '\n=== Plex 服务器工具箱 ===\n1. 安装 Docker（官方脚本）\n2. Docker 安装/配置 usque（SOCKS5）\n3. GitHub 安装/配置 ttyd（Web 终端）\n4. 开启 BBR + fq\n5. 修改 SSH 端口并生效\n0. 退出\n'
        read -r -p '请选择 [0-5]: ' choice || return 0
        case "$choice" in
            0) return 0 ;;
            [1-5])
                # Do not put run_action in an if/||: that disables errexit inside functions.
                set +e
                run_action "$choice"
                rc=$?
                set -e
                if ((rc)); then info '本次操作未完成，已返回菜单。'; fi
                ;;
            *) info '无效选项，请重新输入。' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
