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

check "httpd: start, status, serve, journal, stop" "inactive" 300 '
    systemctl start httpd && echo started
    systemctl is-active httpd
    systemctl status httpd --no-pager | head -n 6
    curl -s -o /dev/null -w "httpd http %{http_code}\n" http://127.0.0.1:8080/
    journalctl -u httpd -n 3
    systemctl stop httpd; sleep 1
    systemctl is-active httpd'
check "nginx (Type=forking, PIDFile, ExecStartPre): start, serve, reload, stop" "nginx http" 300 '
    systemctl start nginx && echo started
    systemctl status nginx --no-pager | head -n 5
    curl -s -o /dev/null -w "nginx http %{http_code}\n" http://127.0.0.1:8081/
    systemctl reload nginx && echo reloaded
    systemctl stop nginx; systemctl is-active nginx'
check "mariadb (User=mysql, %n, ExecStartPre scripts): start, query, stop" "lxterm-sql-ok" 900 '
    systemctl start mariadb && echo started || journalctl -u mariadb -n 30
    systemctl is-active mariadb
    mariadb -e "select concat(\"lxterm-sql-\", \"ok\")" 2>&1
    systemctl stop mariadb; systemctl is-active mariadb'
check "enable: started again when a tab opens" "active" 300 '
    systemctl enable httpd
    systemctl is-enabled httpd
    bash -lc "sleep 3; systemctl is-active httpd; curl -s -o /dev/null -w \"after login %{http_code}\n\" http://127.0.0.1:8080/"
    systemctl disable --now httpd >/dev/null'
check "systemctl help and unknown units" "not found" 60 'systemctl --version; systemctl start nosuchthing; true'
exit $fail
