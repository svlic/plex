#!/usr/bin/env bash
# Run ONLY in the disposable test image; never change the host SSH configuration.
set -Eeuo pipefail
export LANG=C.UTF-8
[[ ${PLEX_TEST_CONTAINER:-} == 1 && -f /.dockerenv ]] || { echo '请在 tests/Dockerfile 构建的临时容器内运行。'; exit 1; }
shellcheck plex.sh tests/smoke.sh
bash -n plex.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

printf 'bad\n0\n' | bash plex.sh > "$WORK/menu"
grep -q '无效选项' "$WORK/menu"
bash plex.sh --help > "$WORK/help"
grep -q '用法' "$WORK/help"

# Exercise the prompts and exact password preservation, including shell metacharacters.
export PLEX_SOURCE=/src/plex.sh
bash <<'BASH'
source "$PLEX_SOURCE"
for p in 1 22 65535 00080; do valid_port "$p" || exit 1; done
for p in 0 65536 -1 abc 123456 '22;id'; do
    if valid_port "$p"; then exit 1; fi
done
ask_port 1080 <<< $'0\n65536\n00880'
[[ $PORT == 880 ]]
ask_credentials <<< $'bad:name\noperator\nshort\nlong password\nwrong password\naB$%"\\: 123\naB$%"\\: 123'
[[ $USERNAME == operator && $PASSWORD == 'aB$%"\: 123' ]]
BASH

# Minimal service controller: real sshd/ttyd processes, no systemd PID 1 in Docker.
cat > /usr/local/bin/systemctl <<'PY'
#!/usr/bin/env python3
import configparser, os, pathlib, shlex, signal, subprocess, sys, time
a = sys.argv[1:]
def stop(name):
    p = pathlib.Path('/run/' + name + '.pid')
    if p.exists():
        try:
            os.kill(int(p.read_text()), signal.SIGTERM)
        except ProcessLookupError:
            pass
        p.unlink(missing_ok=True)
        time.sleep(.15)
if a[0] in ('show-environment', 'daemon-reload', 'enable'):
    sys.exit(0)
if a[0] == 'cat':
    sys.exit(0 if a[1] == 'ssh.service' else 1)
if a[0] in ('is-active', 'is-enabled'):
    if a[-1] == 'ssh.socket':
        sys.exit(0 if pathlib.Path('/tmp/socket-mode').exists() else 1)
    sys.exit(0 if pathlib.Path('/run/plex-ttyd.pid').exists() else 1)
if a[0] in ('restart', 'reload-or-restart'):
    if a[1] == 'ssh.socket':
        sys.exit(0)
    if a[1] == 'ssh.service':
        if pathlib.Path('/tmp/fail-ssh-once').exists():
            pathlib.Path('/tmp/fail-ssh-once').unlink()
            sys.exit(1)
        stop('sshd')
        subprocess.run(['/usr/sbin/sshd'], check=True)
    else:
        stop('plex-ttyd')
        env = {}
        for line in pathlib.Path('/etc/plex/ttyd.env').read_text().splitlines():
            k, v = line.split('=', 1)
            # shlex decodes the same double-quote/backslash forms emitted here.
            env[k] = shlex.split(v)[0]
        unit = configparser.ConfigParser(interpolation=None)
        unit.read('/etc/systemd/system/plex-ttyd.service')
        service = unit['Service']
        args = shlex.split(service['ExecStart'])
        args = [env.get(arg[2:-1], arg) if arg.startswith('${') and arg.endswith('}') else arg for arg in args]
        log = open('/tmp/ttyd.log', 'ab')
        p = subprocess.Popen(args, user=service['User'], group=service['Group'],
            cwd=service['WorkingDirectory'], stdout=log, stderr=log)
        pathlib.Path('/run/plex-ttyd.pid').write_text(str(p.pid))
    sys.exit(0)
raise SystemExit('unexpected systemctl command: ' + repr(a))
PY
chmod +x /usr/local/bin/systemctl
mkdir -p /run/sshd /etc/ssh/sshd_config.d
ssh-keygen -A
cat > /etc/ssh/sshd_config <<'SSH'
Include /etc/ssh/sshd_config.d/*.conf

Port = 22221
PidFile /run/sshd.pid
UsePAM no
Match User nobody
    X11Forwarding no
SSH
printf '\n\n\tpOrT=22222\n' > /etc/ssh/sshd_config.d/ports.conf
/usr/sbin/sshd
printf '23456\ny\n' | bash plex.sh ssh
[[ $(sshd -T | awk '$1 == "port" {print $2}') == 23456 ]]
ssh-keyscan -T 3 -p 23456 127.0.0.1 > "$WORK/keyscan" 2>/dev/null
[[ -s $WORK/keyscan ]]
[[ -z $(ss -H -ltn 'sport = :22221') ]]
grep -q 'Match User nobody' /etc/ssh/sshd_config
cp /etc/ssh/sshd_config "$WORK/before"

# A service-apply failure must restore the old files and the old listening port.
touch /tmp/fail-ssh-once
if printf '23457\ny\n' | bash plex.sh ssh; then echo 'expected SSH apply failure'; exit 1; fi
cmp "$WORK/before" /etc/ssh/sshd_config
ssh-keyscan -T 3 -p 23456 127.0.0.1 > "$WORK/keyscan" 2>/dev/null
[[ -s $WORK/keyscan ]]

# Unhandled external Includes / explicit ListenAddress ports must not silently retain old ports.
printf 'ListenAddress 127.0.0.1:23456\n' >> /etc/ssh/sshd_config.d/ports.conf
cp /etc/ssh/sshd_config.d/ports.conf "$WORK/listen-before"
if printf '23458\ny\n' | bash plex.sh ssh; then echo 'expected ListenAddress conflict'; exit 1; fi
cmp "$WORK/before" /etc/ssh/sshd_config
cmp "$WORK/listen-before" /etc/ssh/sshd_config.d/ports.conf
sed -i '/^ListenAddress/d' /etc/ssh/sshd_config.d/ports.conf
touch /tmp/socket-mode
printf '23459\ny\n' | bash plex.sh ssh
grep -q '^ListenStream=23459$' /etc/systemd/system/ssh.socket.d/plex.conf
ssh-keyscan -T 3 -p 23459 127.0.0.1 > "$WORK/keyscan" 2>/dev/null
[[ -s $WORK/keyscan ]]

# Real GitHub download, checksum, executable and HTTP authentication.
password='aB$%"\: 123'
printf 'operator\n%s\n%s\n27681\nn\n' "$password" "$password" | bash plex.sh ttyd
[[ $(stat -c %a /etc/plex/ttyd.env) == 600 ]]
[[ $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:27681/) == 401 ]]
[[ $(curl -s -u 'operator:wrong' -o /dev/null -w '%{http_code}' http://127.0.0.1:27681/) == 401 ]]
[[ $(curl -s -u "operator:$password" -o /dev/null -w '%{http_code}' http://127.0.0.1:27681/) == 200 ]]
[[ $(ps -o user= -p "$(cat /run/plex-ttyd.pid)" | xargs) == root ]]
[[ $(readlink "/proc/$(cat /run/plex-ttyd.pid)/cwd") == /root ]]
systemd-analyze verify /etc/systemd/system/plex-ttyd.service
# Reconfigure existing install to a different port/password; the previous listener must close.
printf 'other\nother-password\nother-password\n27682\nn\ny\n' | bash plex.sh ttyd
[[ $(curl -s -u other:other-password -o /dev/null -w '%{http_code}' http://127.0.0.1:27682/) == 200 ]]
[[ -z $(ss -H -ltn 'sport = :27681') ]]

# Kernel writes are simulated: Docker shares the host kernel.
cat > /usr/local/bin/sysctl <<'SH'
#!/usr/bin/env bash
if [[ $* == '-n net.ipv4.tcp_available_congestion_control' ]]; then echo 'reno cubic bbr';
elif [[ $* == '-n net.ipv4.tcp_congestion_control' ]]; then echo cubic;
elif [[ $* == '-n net.core.default_qdisc' ]]; then echo fq_codel;
elif [[ $1 == -w && -f /tmp/fail-sysctl ]]; then exit 1;
else printf '%s\n' "$*"; fi
SH
chmod +x /usr/local/bin/sysctl
bash plex.sh bbr
grep -q '^net.core.default_qdisc = fq$' /etc/sysctl.d/99-plex-bbr.conf
grep -q '^net.ipv4.tcp_congestion_control = bbr$' /etc/sysctl.d/99-plex-bbr.conf
rm /etc/sysctl.d/99-plex-bbr.conf
touch /tmp/fail-sysctl
if bash plex.sh bbr; then echo 'expected BBR permission failure'; exit 1; fi
[[ ! -e /etc/sysctl.d/99-plex-bbr.conf ]]
printf '4\n0\n' | bash plex.sh > "$WORK/failure-menu" 2>&1
grep -q '本次操作未完成' "$WORK/failure-menu"

# Docker state is simulated: never mount the host Docker socket in this container.
cat > /usr/local/bin/docker <<'PY'
#!/usr/bin/env python3
import json, pathlib, sys
a = sys.argv[1:]
state = pathlib.Path('/tmp/docker-state.json')
containers = json.loads(state.read_text()) if state.exists() else {}
if a[0] in ('info', 'build', '--version'):
    print('Docker test double')
elif a[:2] == ['container', 'inspect']:
    sys.exit(0 if a[2] in containers else 1)
elif a[0] == 'inspect':
    if 'Labels' in a[2]: print('true')
    else: print('true 0')
elif a[0] == 'rename':
    containers[a[2]] = containers.pop(a[1])
elif a[0] in ('stop', 'start'):
    containers[a[1]]['running'] = a[0] == 'start'
elif a[0] == 'rm':
    containers.pop(a[-1], None)
elif a[0] == 'run':
    if '--rm' in a:
        pathlib.Path('/var/lib/plex/usque/config.json').write_text('{"test_registration": true}')
    else:
        if pathlib.Path('/tmp/fail-docker').exists(): sys.exit(1)
        containers['plex-usque'] = {'running': True, 'args': a}
else:
    raise SystemExit('unexpected docker command: ' + repr(a))
state.write_text(json.dumps(containers))
PY
chmod +x /usr/local/bin/docker
bash plex.sh docker > "$WORK/docker-existing"
grep -q '未重复安装' "$WORK/docker-existing"
printf 'proxy\nproxy-password\nproxy-password\n21080\nn\n' | bash plex.sh usque
cp /tmp/docker-state.json "$WORK/docker-before"
cp /var/lib/plex/usque/config.json "$WORK/warp-before"
python3 - <<'PY'
import json
c = json.load(open('/tmp/docker-state.json'))['plex-usque']
a = c['args']
assert '127.0.0.1:21080:1080/tcp' in a and '127.0.0.1:21080:1080/udp' in a
assert a[a.index('-u')+1] == 'proxy' and a[a.index('-w')+1] == 'proxy-password'
PY
touch /tmp/fail-docker
if printf 'proxy\nnew-password\nnew-password\n21081\nn\ny\n' | bash plex.sh usque; then
    echo 'expected container start failure'; exit 1
fi
cmp "$WORK/docker-before" /tmp/docker-state.json
cmp "$WORK/warp-before" /var/lib/plex/usque/config.json
echo 'PASS: prompts, SSH listener/rollback, socket config, ttyd auth/reconfiguration, BBR handling, Docker orchestration/rollback'
