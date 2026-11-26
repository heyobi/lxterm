#!/bin/sh
# LxTerm's systemctl (lxios/LxTerm/systemctl.sh) on a distribution's official root:
# packages installed with its package manager, their services started, checked, logged
# and stopped as a user would in a tab. Each block runs in one lxrun (the services live
# as long as it does, as they live while LxTerm is open).
# usage: tests/linux/run_services.sh ROOT NAME   (rpm distributions: dnf)
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
R=$1; N=$2
L="$DIR/build/lxrun"
fail=0
mkdir -p "$R/usr/local/bin" "$R/etc/profile.d"
cp "$DIR/lxios/LxTerm/systemctl.sh" "$R/usr/local/bin/systemctl"; chmod 755 "$R/usr/local/bin/systemctl"
ln -sf systemctl "$R/usr/local/bin/journalctl"
printf '[ -d /etc/lxterm/autostart ] && [ -x /usr/local/bin/systemctl ] && (/usr/local/bin/systemctl --lxterm-autostart >/dev/null 2>&1 &)\n' > "$R/etc/profile.d/lxterm-services.sh"
cp /etc/resolv.conf "$R/etc/resolv.conf"
grep -qw iphone "$R/etc/hosts" 2>/dev/null || printf '127.0.0.1\tiphone\t# LxTerm: the name of this machine\n' >> "$R/etc/hosts"   # (Distros.swift nameInHosts)
lx() { LXRUN_QUIET=1 timeout "$1" "$L" "$R" /bin/bash -lc "$2" 2>&1; }
check() {   # check NAME EXPECTED TIMEOUT SCRIPT
    t0=$(date +%s)
    out=$(lx "$3" "$4"); rc=$?
    if printf '%s\n' "$out" | grep -qF -- "$2"; then echo "OK   $N: $1 ($(( $(date +%s) - t0 )) s)"
    else echo "FAIL $N: $1 (rc=$rc)"; fail=1; fi
    printf '%s\n' "$out" | tail -n 25 | sed 's/^/     | /'
}

check "install httpd nginx mariadb-server" "Complete" 3000 \
    'dnf -y --setopt=install_weak_deps=False install httpd nginx mariadb-server 2>&1 | tail -n 3'
sed -i 's/^Listen 80$/Listen 8080/' "$R/etc/httpd/conf/httpd.conf"
sed -i 's/listen       80;/listen       8081;/; s/listen       \[::\]:80;/listen       [::]:8081;/' "$R/etc/nginx/nginx.conf"

check "httpd: start, status, serve, journal, stop" "httpd served" 300 '
    systemctl start httpd && echo started
    systemctl is-active httpd
    systemctl status httpd --no-pager | head -n 6
    code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/); [ "$code" != 000 ] && echo "httpd served $code"
    journalctl -u httpd -n 5
    [ "$code" = 000 ] && tail -n 15 /var/log/httpd/error_log
    systemctl stop httpd; sleep 1
    systemctl is-active httpd'
check "nginx (Type=forking, PIDFile, ExecStartPre): start, serve, reload, stop" "nginx served" 300 '
    systemctl start nginx && echo started
    systemctl status nginx --no-pager | head -n 5
    code=$(curl -s --max-time 15 -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/); [ "$code" != 000 ] && echo "nginx served $code"
    [ "$code" = 000 ] && { echo "== nginx error.log"; tail -n 20 /var/log/nginx/error.log; journalctl -u nginx -n 20; }
    timeout 20 systemctl reload nginx && echo reloaded
    timeout 30 systemctl stop nginx; systemctl is-active nginx'
# MariaDB: not yet (its setup does not finish under the core; see apk-on-iphone docs/STATUS.md)
check "enable: started again when a tab opens" "after login 403" 300 '
    systemctl enable httpd
    systemctl is-enabled httpd
    bash -lc "for i in \$(seq 60); do systemctl is-active -q httpd && break; sleep 1; done; sleep 2; systemctl is-active httpd; curl -s --max-time 15 -o /dev/null -w \"after login %{http_code}\n\" http://127.0.0.1:8080/"
    systemctl disable --now httpd >/dev/null'
check "systemctl help and unknown units" "not found" 60 'systemctl --version; systemctl start nosuchthing; true'
exit $fail
