#!/bin/sh
# LxTerm's systemctl (and journalctl): runs the services packages install, without systemd.
#
# A tab in LxTerm has no init system: the iPhone does not let an app be one, so systemd
# cannot run as PID 1. This stand-in reads the same unit files (/etc/systemd/system,
# /usr/lib/systemd/system...) and does what systemd would do for a service: runs
# ExecStartPre/ExecStart/ExecStartPost with its Environment, EnvironmentFile and
# WorkingDirectory, keeps its main PID, writes its output to a log, stops it with
# ExecStop or a signal. Services run while LxTerm is open (iOS pauses apps it does not
# show); enabled ones start again when a tab opens (/etc/profile.d/lxterm-services.sh).
# Package scripts still use the distribution's own systemctl (it works offline, in
# /usr/bin); this one is /usr/local/bin/systemctl, found first in a tab's PATH.
#
# Not done: sockets, timers, targets, dependencies between units (After=, Requires=),
# cgroups, restarts on failure. User= runs the service as that user (runuser or su).
# Installed and updated by LxTerm; changes here are overwritten.
LXV=1
ST=/run/lxterm/units
LOGS=/var/log/lxterm
AUTO=/etc/lxterm/autostart
DIRS="/etc/systemd/system /run/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system /lib/systemd/system"
mkdir -p "$ST" "$LOGS" 2>/dev/null

say() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

unitname() {   # unitname NAME -> NAME.service unless it has a suffix
    case $1 in *.service|*.socket|*.timer|*.target|*.mount|*.path) printf '%s' "$1" ;; *) printf '%s.service' "$1" ;; esac
}

unitfile() {   # unitfile UNIT -> path of the unit file (templates: name@.service)
    u=$1
    for d in $DIRS; do [ -f "$d/$u" ] && { printf '%s' "$d/$u"; return 0; }; done
    case $u in *@*.*)
        t="${u%%@*}@.${u##*.}"
        for d in $DIRS; do [ -f "$d/$t" ] && { printf '%s' "$d/$t"; return 0; }; done ;;
    esac
    return 1
}

# key UNIT-FILE SECTION KEY -> every value of KEY in SECTION (one per line, in order),
# with drop-ins (UNIT.d/*.conf) after; an empty value resets the list, as in systemd.
key() {
    f=$1 sec=$2 k=$3
    { cat "$f"; for d in $DIRS; do for c in "$d/$(basename "$f").d"/*.conf; do [ -f "$c" ] && cat "$c"; done; done; } 2>/dev/null |
    awk -v sec="[$sec]" -v k="$k" '
        { sub(/\r$/, "") }
        /^[ \t]*[#;]/ { next }
        /^\[/ { in_sec = ($0 == sec); next }
        in_sec {
            line = $0
            while (line ~ /\\$/) { sub(/\\$/, "", line); if ((getline nx) > 0) line = line " " nx; else break }
            i = index(line, "=")
            if (!i) next
            name = substr(line, 1, i - 1); gsub(/[ \t]/, "", name)
            if (name != k) next
            val = substr(line, i + 1); sub(/^[ \t]+/, "", val)
            if (val == "") { n = 0; next }
            v[++n] = val
        }
        END { for (j = 1; j <= n; j++) print v[j] }'
}
first() { key "$@" | head -n 1; }

spec() {   # systemd specifiers in a command line: %i %I %n %N %p %t %% (enough for packaged units)
    printf '%s' "$1" | sed -e 's/%%/@LXPCT@/g' -e "s|%i|$INST|g" -e "s|%I|$INST|g" -e "s|%n|$UNIT|g"         -e "s|%N|${UNIT%.*}|g" -e "s|%p|$PREFIX|g" -e 's|%t|/run|g' -e 's/@LXPCT@/%/g'
}

load_env() {   # the unit's Environment= and EnvironmentFile= into this shell, exported
    key "$F" Service EnvironmentFile | while IFS= read -r ef; do printf '%s\n' "$ef"; done > "$ST/.envfiles.$$"
    while IFS= read -r ef; do
        case $ef in -*) ef=${ef#-} ;; esac
        [ -r "$ef" ] || continue
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in ''|'#'*|';'*) continue ;; esac
            k=${line%%=*} v=${line#*=}
            case $v in \"*\") v=${v#\"}; v=${v%\"} ;; \'*\') v=${v#\'}; v=${v%\'} ;; esac
            case $k in *[!A-Za-z0-9_]*|'') continue ;; esac
            export "$k=$v"
        done < "$ef"
    done < "$ST/.envfiles.$$"
    rm -f "$ST/.envfiles.$$"
    key "$F" Service Environment > "$ST/.env.$$"
    while IFS= read -r line; do
        eval "set -- $line" 2>/dev/null || continue
        for kv in "$@"; do
            k=${kv%%=*}
            case $k in *[!A-Za-z0-9_]*|'') continue ;; esac
            export "$kv"
        done
    done < "$ST/.env.$$"
    rm -f "$ST/.env.$$"
}

dirs() {   # RuntimeDirectory= and friends: made before the service starts
    for pair in "RuntimeDirectory /run" "StateDirectory /var/lib" "CacheDirectory /var/cache" "LogsDirectory /var/log" "ConfigurationDirectory /etc"; do
        set -- $pair
        for d in $(key "$F" Service "$1"); do mkdir -p "$2/$d"; done
    done
}

# run_cmd LINE [bg]: one Exec line ("-" in front: its failure does not count); bg starts
# it in its own session in the background and prints its PID.
run_cmd() {
    line=$(spec "$1") ign=0
    while :; do
        case $line in -*) ign=1; line=${line#-} ;; [@+!:]*) line=${line#?} ;; *) break ;; esac
    done
    if [ -n "$RUNAS" ]; then                                       # User=: as that user (runuser, else su)
        if command -v runuser >/dev/null 2>&1; then line="runuser -u $RUNAS -- sh -c 'exec $line'"
        else line="su -s /bin/sh $RUNAS -c 'exec $line'"; fi
    fi
    if [ "${2:-}" = bg ]; then
        ( cd "${WD:-/}" 2>/dev/null; exec setsid sh -c "exec $line" >> "$LOG" 2>&1 < /dev/null ) &
        printf '%s' "$!"
        return 0
    fi
    ( cd "${WD:-/}" 2>/dev/null; eval "$line" ) >> "$LOG" 2>&1 < /dev/null
    rc=$?
    [ $ign = 1 ] && return 0
    return $rc
}

setup() {   # setup NAME: UNIT, F, LOG, WD, TYPE... for one unit; 1 if there is no such unit
    UNIT=$(unitname "$1")
    case $UNIT in *@*) INST=${UNIT#*@}; INST=${INST%.*}; PREFIX=${UNIT%%@*} ;; *) INST="" PREFIX=${UNIT%.*} ;; esac
    F=$(unitfile "$UNIT") || return 1
    LOG="$LOGS/$UNIT.log"
    WD=$(first "$F" Service WorkingDirectory); WD=${WD#-}; [ "$WD" = "~" ] && WD=/root
    TYPE=$(first "$F" Service Type); [ -n "$TYPE" ] || TYPE=simple
    [ -n "$(first "$F" Service BusName)" ] && [ -z "$(first "$F" Service Type)" ] && TYPE=dbus
    PIDF=$(spec "$(first "$F" Service PIDFile)")
    RUNAS=$(first "$F" Service User); [ "$RUNAS" = root ] || [ "$RUNAS" = 0 ] && RUNAS=""
    return 0
}

mainpid() { [ -f "$ST/$UNIT.pid" ] && cat "$ST/$UNIT.pid"; }
running() { p=$(mainpid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
state() {   # active, inactive or failed
    if running; then echo active
    elif [ -f "$ST/$UNIT.exited" ]; then echo active
    elif [ -f "$ST/$UNIT.failed" ]; then echo failed
    else echo inactive; fi
}

# One start of a unit at a time: two tabs opened together both run the autostart, and the
# second must find the service running, not start it again. (mkdir is atomic; a lock
# left by an ended LxTerm is cleared when it starts again, or here after ~30 s.)
start() {
    lk="$ST/$(unitname "$1").lock" tries=0
    while ! mkdir "$lk" 2>/dev/null; do
        tries=$((tries + 1))
        if [ $tries -gt 100 ]; then rmdir "$lk" 2>/dev/null; tries=0; continue; fi
        sleep 0.3
    done
    start_unlocked "$1"; src=$?
    rmdir "$lk" 2>/dev/null
    return $src
}

start_unlocked() {
    setup "$1" || { err "Failed to start $(unitname "$1"): Unit $(unitname "$1") not found."; return 5; }
    case $UNIT in *.service) ;; *) err "LxTerm: only services can be started ($UNIT)"; return 1 ;; esac
    [ "$(state)" = active ] && return 0
    rm -f "$ST/$UNIT.failed" "$ST/$UNIT.exited"
    load_env; dirs
    printf '\n-- %s: starting (LxTerm)\n' "$(date '+%b %d %H:%M:%S')" >> "$LOG"
    key "$F" Service ExecStartPre > "$ST/.pre.$$"
    while IFS= read -r c; do run_cmd "$c" || { rm -f "$ST/.pre.$$"; touch "$ST/$UNIT.failed"; err "Job for $UNIT failed (ExecStartPre). See \"journalctl -u $UNIT\"."; return 1; }; done < "$ST/.pre.$$"
    rm -f "$ST/.pre.$$"
    cmd=$(first "$F" Service ExecStart)
    case $TYPE in
    oneshot)
        key "$F" Service ExecStart > "$ST/.ex.$$"
        while IFS= read -r c; do run_cmd "$c" || { rm -f "$ST/.ex.$$"; touch "$ST/$UNIT.failed"; err "Job for $UNIT failed. See \"journalctl -u $UNIT\"."; return 1; }; done < "$ST/.ex.$$"
        rm -f "$ST/.ex.$$"
        case $(first "$F" Service RemainAfterExit) in yes|true|1|on) touch "$ST/$UNIT.exited" ;; esac
        ;;
    forking)
        [ -n "$PIDF" ] && rm -f "$PIDF"
        run_cmd "$cmd" || { touch "$ST/$UNIT.failed"; err "Job for $UNIT failed. See \"journalctl -u $UNIT\"."; return 1; }
        n=0; while [ -n "$PIDF" ] && [ ! -s "$PIDF" ] && [ $n -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
        if [ -n "$PIDF" ] && [ -s "$PIDF" ]; then head -n 1 "$PIDF" | tr -dc 0-9 > "$ST/$UNIT.pid"
        else touch "$ST/$UNIT.exited"; fi
        ;;
    *)  # simple, exec, notify, dbus, idle: the command is the service
        [ -n "$cmd" ] || { err "$UNIT has no ExecStart="; return 1; }
        run_cmd "$cmd" bg > "$ST/$UNIT.pid"
        sleep 0.5
        running || { rm -f "$ST/$UNIT.pid"; touch "$ST/$UNIT.failed"; err "Job for $UNIT failed because the service exited. See \"journalctl -u $UNIT\"."; return 1; }
        ;;
    esac
    key "$F" Service ExecStartPost > "$ST/.post.$$"
    while IFS= read -r c; do run_cmd "$c" || true; done < "$ST/.post.$$"
    rm -f "$ST/.post.$$"
    return 0
}

stop() {
    setup "$1" || { err "Failed to stop $(unitname "$1"): Unit $(unitname "$1") not loaded."; return 5; }
    load_env
    p=$(mainpid)
    export MAINPID="$p"
    if running; then
        key "$F" Service ExecStop > "$ST/.stop.$$"
        if [ -s "$ST/.stop.$$" ]; then while IFS= read -r c; do run_cmd "$c" || true; done < "$ST/.stop.$$"; fi
        rm -f "$ST/.stop.$$"
        n=0; while kill -0 "$p" 2>/dev/null && [ $n -lt 10 ]; do [ $n = 0 ] && kill -TERM "$p" 2>/dev/null; sleep 0.3; n=$((n + 1)); done
        kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
        kill -TERM -"$p" 2>/dev/null                               # (what is left of its session)
    elif [ -f "$ST/$UNIT.exited" ]; then
        key "$F" Service ExecStop > "$ST/.stop.$$"
        while IFS= read -r c; do run_cmd "$c" || true; done < "$ST/.stop.$$"
        rm -f "$ST/.stop.$$"
    fi
    rm -f "$ST/$UNIT.pid" "$ST/$UNIT.exited" "$ST/$UNIT.failed"
    printf -- '-- %s: stopped (LxTerm)\n' "$(date '+%b %d %H:%M:%S')" >> "$LOG"
    return 0
}

reload() {
    setup "$1" || return 5
    running || { err "$UNIT is not active, cannot reload."; return 7; }
    load_env
    export MAINPID="$(mainpid)"
    c=$(first "$F" Service ExecReload)
    if [ -n "$c" ]; then run_cmd "$c"; else kill -HUP "$MAINPID"; fi
}

enabled() { [ -f "$AUTO/$UNIT" ] && echo enabled || { [ -n "$(first "$F" Install WantedBy)" ] && echo disabled || echo static; }; }

status() {
    setup "$1" || { err "Unit $(unitname "$1") could not be found."; return 4; }
    desc=$(first "$F" Unit Description)
    s=$(state)
    case $s in active) dot="\033[1;32m●\033[0m" ;; failed) dot="\033[1;31m×\033[0m" ;; *) dot="○" ;; esac
    printf "$dot %s - %s\n" "$UNIT" "${desc:-$UNIT}"
    printf '     Loaded: loaded (%s; %s)\n' "$F" "$(enabled)"
    if running; then
        since=$(date -r "$ST/$UNIT.pid" '+%a %Y-%m-%d %H:%M:%S' 2>/dev/null)
        printf "     Active: \033[1;32mactive (running)\033[0m since %s\n" "$since"
        p=$(mainpid)
        printf '   Main PID: %s (%s)\n' "$p" "$(cat /proc/"$p"/comm 2>/dev/null || echo ?)"
    elif [ -f "$ST/$UNIT.exited" ]; then printf "     Active: \033[1;32mactive (exited)\033[0m\n"
    elif [ "$s" = failed ]; then printf "     Active: \033[1;31mfailed\033[0m\n"
    else printf '     Active: inactive (dead)\n'; fi
    printf '       Note: run by LxTerm (no systemd on iPhone): while LxTerm is open\n'
    if [ -f "$LOG" ]; then echo; tail -n 10 "$LOG"; fi
    [ "$s" = active ] && return 0 || return 3
}

autostart() {   # (a tab opened) enabled services that are not running yet
    [ -d "$AUTO" ] || return 0
    for f in "$AUTO"/*; do
        [ -f "$f" ] || continue
        u=$(basename "$f")
        setup "$u" || continue
        [ "$(state)" = active ] || start "$u" > /dev/null 2>&1
    done
}

list_units() {
    printf '  %-40s %-8s %-8s %s\n' UNIT ACTIVE SUB DESCRIPTION
    for f in "$ST"/*.pid "$ST"/*.exited "$ST"/*.failed; do
        [ -f "$f" ] || continue
        u=$(basename "$f"); u=${u%.*}
        setup "$u" || continue
        s=$(state); sub=dead
        running && sub=running; [ -f "$ST/$UNIT.exited" ] && sub=exited; [ "$s" = failed ] && sub=failed
        printf '  %-40s %-8s %-8s %s\n' "$UNIT" "$s" "$sub" "$(first "$F" Unit Description)"
    done | sort -u
}

list_files() {
    printf '%-44s %s\n' "UNIT FILE" STATE
    for d in $DIRS; do for f in "$d"/*.service; do [ -f "$f" ] && basename "$f"; done; done | sort -u | while read -r u; do
        setup "$u" || continue
        printf '%-44s %s\n' "$UNIT" "$(enabled)"
    done
}

journal() {   # journalctl [-u UNIT]... [-f] [-n N] [--no-pager] [-e] [-b]
    units="" follow=0 n=""
    while [ $# -gt 0 ]; do
        case $1 in
        -u|--unit) units="$units $(unitname "$2")"; shift ;;
        -u*) units="$units $(unitname "${1#-u}")" ;;
        --unit=*) units="$units $(unitname "${1#--unit=}")" ;;
        -f|--follow) follow=1 ;;
        -n|--lines) n=$2; shift ;;
        -n*) n=${1#-n} ;;
        -e|--pager-end) n=${n:-1000} ;;
        *) ;;
        esac
        shift
    done
    if [ -z "$units" ]; then files=$(ls "$LOGS"/*.log 2>/dev/null)
    else files=""; for u in $units; do files="$files $LOGS/$u.log"; done; fi
    [ -n "$files" ] || { echo "-- No entries (LxTerm keeps the output of the services it runs in $LOGS) --"; return 0; }
    if [ $follow = 1 ]; then exec tail -n "${n:-10}" -f $files; fi
    if [ -n "$n" ]; then tail -q -n "$n" $files 2>/dev/null; else cat $files 2>/dev/null; fi
}

me=$(basename "$0")
if [ "$me" = journalctl ]; then journal "$@"; exit $?; fi

now=0 quiet=0 args=""
for a in "$@"; do
    case $a in
    --now) now=1 ;;
    -q|--quiet) quiet=1 ;;
    --no-pager|--no-block|--no-ask-password|--system|-l|--full|--no-legend|--plain|--all|-a) ;;
    --user) err "LxTerm: user services are not supported"; exit 1 ;;
    --version) say "systemd 0 (LxTerm's systemctl $LXV: services without systemd; see 'systemctl help')"; exit 0 ;;
    --lxterm-autostart) autostart; exit 0 ;;
    -*) ;;
    *) args="$args $a" ;;
    esac
done
set -- $args
cmd=${1:-list-units}; [ $# -gt 0 ] && shift
rc=0
case $cmd in
start)          for u in "$@"; do start "$u" || rc=$?; done ;;
stop)           for u in "$@"; do stop "$u" || rc=$?; done ;;
restart|try-restart|reload-or-restart|condrestart)
                for u in "$@"; do
                    if [ "$cmd" = try-restart ] || [ "$cmd" = condrestart ]; then setup "$u" && [ "$(state)" = active ] || continue; fi
                    stop "$u" > /dev/null 2>&1; start "$u" || rc=$?
                done ;;
reload)         for u in "$@"; do reload "$u" || rc=$?; done ;;
status)         if [ $# = 0 ]; then list_units; else for u in "$@"; do status "$u" || rc=$?; echo; done; fi ;;
is-active)      for u in "$@"; do setup "$u" && s=$(state) || s=inactive; [ $quiet = 1 ] || say "$s"; [ "$s" = active ] || rc=3; done ;;
is-failed)      for u in "$@"; do setup "$u" && s=$(state) || s=inactive; [ $quiet = 1 ] || say "$s"; [ "$s" = failed ] || rc=1; done ;;
is-enabled)     for u in "$@"; do if setup "$u"; then s=$(enabled); else s=not-found; fi; [ $quiet = 1 ] || say "$s"; [ "$s" = enabled ] || rc=1; done ;;
enable)         mkdir -p "$AUTO"
                for u in "$@"; do
                    setup "$u" || { err "Failed to enable unit: Unit $(unitname "$u") does not exist"; rc=1; continue; }
                    touch "$AUTO/$UNIT"; [ $quiet = 1 ] || say "Enabled $UNIT: LxTerm starts it when a tab opens."
                    [ $now = 1 ] && { start "$u" || rc=$?; }
                done ;;
disable)        for u in "$@"; do
                    setup "$u" || continue
                    rm -f "$AUTO/$UNIT"; [ $quiet = 1 ] || say "Disabled $UNIT."
                    [ $now = 1 ] && stop "$u"
                done ;;
mask|unmask|preset|preset-all|daemon-reload|daemon-reexec|reset-failed|link|revert|set-property|edit)
                [ "$cmd" = reset-failed ] && rm -f "$ST"/*.failed
                ;;
cat)            for u in "$@"; do setup "$u" && { say "# $F"; cat "$F"; } || rc=1; done ;;
show)           for u in "$@"; do
                    setup "$u" || { rc=1; continue; }
                    say "Id=$UNIT"; say "ActiveState=$(state)"; say "UnitFileState=$(enabled)"; say "MainPID=$(mainpid || echo 0)"
                    say "Description=$(first "$F" Unit Description)"; say "FragmentPath=$F"
                done ;;
list-units|list-unit-files)
                if [ "$cmd" = list-units ]; then list_units; else list_files; fi ;;
kill)           for u in "$@"; do setup "$u" && running && kill -TERM "$(mainpid)"; done ;;
help|-h|--help) say "LxTerm's systemctl: services without systemd (it cannot run on iPhone)."
                say "  start|stop|restart|reload|status|enable [--now]|disable|is-active|is-enabled UNIT..."
                say "  list-units, list-unit-files, cat UNIT, show UNIT; journalctl -u UNIT [-f] [-n N]"
                say "Services run while LxTerm is open; enabled ones start again when a tab opens." ;;
poweroff|reboot|halt|suspend|hibernate|isolate|default|rescue|emergency|switch-root)
                err "LxTerm: $cmd is not possible here (no init system on iPhone)."; rc=1 ;;
*)              err "LxTerm's systemctl: '$cmd' is not supported ('systemctl help')."; rc=1 ;;
esac
exit $rc
