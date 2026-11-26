/* The app's bridge to the core: see engine.h. */
#define _DARWIN_C_SOURCE
#include "engine.h"
#include "../../core/proc.h"
#include "../../core/tty.h"
#include "untar.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <resolv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

struct lx_session {
    struct aoi_proc *p;
    struct aoi_tty *tty;
    char snap[1024];
    void (*out)(void *ctx, const char *s, size_t n);
    void (*exited)(void *ctx);
    void *ctx;
    volatile int closing, running;
};

static char g_root[1024];
static FILE *g_trace;

void lx_engine_trace(const char *path)
{
    char child[1100];
    if (!(g_trace = fopen(path, "w"))) return;
    setvbuf(g_trace, NULL, _IOLBF, 0);
    snprintf(child, sizeof child, "%s.children", path);
    setenv("AOI_CHILD_TRACE", child, 1);                           /* (vfork + execve children: core/proc.c) */
}

static void write_resolv(const char *root)
{
    char path[1100];
    FILE *f;
    struct __res_state rs;
    int n = 0;
    snprintf(path, sizeof path, "%s/etc/resolv.conf", root);
    unlink(path);
    if (!(f = fopen(path, "w"))) return;
    memset(&rs, 0, sizeof rs);
    if (res_ninit(&rs) == 0) {
        union res_sockaddr_union sv[4];
        int i, k = res_getservers(&rs, sv, 4);
        for (i = 0; i < k; i++) {
            char a[64];
            if (sv[i].sin.sin_family == AF_INET && inet_ntop(AF_INET, &sv[i].sin.sin_addr, a, sizeof a)) {
                fprintf(f, "nameserver %s\n", a);
                n++;
            }
        }
        res_ndestroy(&rs);
    }
    /* a public server after the phone's own, and short timeouts: glibc waited 5 s on each
     * server that did not answer (a root kept the file of the network it was written on).
     * single-request-reopen: the A and AAAA questions one after the other, each on its own
     * socket - sent together (sendmmsg), one answer got lost on some networks (an ISP's
     * resolver here) and every lookup waited out the timeout: 6.4 s instead of 0.03 */
    if (n < 3) fprintf(f, "nameserver 1.1.1.1\n");
    if (!n) fprintf(f, "nameserver 8.8.8.8\n");
    fprintf(f, "options single-request-reopen timeout:1 attempts:2\n");
    fclose(f);
}

void lx_engine_init(const char *root)
{
    struct rlimit rl;
    snprintf(g_root, sizeof g_root, "%s", root);
    if (!getrlimit(RLIMIT_NOFILE, &rl) && rl.rlim_cur < 4096) {   /* every process dups its fds */
        rl.rlim_cur = rl.rlim_max < 4096 ? rl.rlim_max : 4096;
        setrlimit(RLIMIT_NOFILE, &rl);
    }
    write_resolv(root);
    aoi_proc_zygote("/usr/bin/dnf-3", "/usr/bin/python3", "/usr/lib/lxzygote/zygote-dnf.py",   /* dnf's fast start */
                    "/var/lib/rpm/rpmdb.sqlite");                                             /* (Distros.swift installFastStart) */
}

void lx_engine_bind_files(const char *host)
{
    char d[1100];
    snprintf(d, sizeof d, "%s/root/Files", g_root);              /* (so that ls /root shows it) */
    mkdir(d, 0755);
    aoi_proc_bind("/root/Files", host);
}

void lx_engine_prepare_root(const char *root)
{
    char d[1100];
    write_resolv(root);
    snprintf(d, sizeof d, "%s/root", root);
    mkdir(d, 0700);
    snprintf(d, sizeof d, "%s/root/Files", root);
    mkdir(d, 0755);
}

int lx_engine_listening(int *ports, char *names, int max)
{
    struct rlimit rl;
    int fd, n = 0, top = 4096, i;
    if (!getrlimit(RLIMIT_NOFILE, &rl) && rl.rlim_cur < (rlim_t)top) top = (int)rl.rlim_cur;
    for (fd = 0; fd < top && n < max; fd++) {
        int acc = 0, type = 0;
        socklen_t l = sizeof acc;
        struct sockaddr_storage sa;
        socklen_t sl = sizeof sa;
        int port = 0;
        struct sockaddr_storage peer;
        socklen_t pl = sizeof peer;
        int known;
        l = sizeof type;
        if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &l) || type != SOCK_STREAM) continue;
        l = sizeof acc;
        known = !getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &acc, &l);
        if (known && !acc) continue;
        if (getsockname(fd, (struct sockaddr *)&sa, &sl)) continue;
        if (sa.ss_family == AF_INET) port = ntohs(((struct sockaddr_in *)&sa)->sin_port);
        else if (sa.ss_family == AF_INET6) port = ntohs(((struct sockaddr_in6 *)&sa)->sin6_port);
        else continue;
        if (!known) {                                              /* (no SO_ACCEPTCONN: not connected, not an ephemeral port) */
            if (!getpeername(fd, (struct sockaddr *)&peer, &pl) || errno != ENOTCONN || port >= 49152) continue;
        }
        for (i = 0; i < n && ports[i] != port; i++) {}
        if (!port || i < n) continue;                              /* (IPv4 and IPv6 on one port: once) */
        ports[n] = port;
        if (aoi_proc_listener_name(port, names + 40 * n, 40)) names[40 * n] = 0;
        n++;
    }
    return n;
}

const char *lx_unpack(const char *archive, const char *dir, unsigned long *files,
                      void (*progress)(void *ctx, double f), void *ctx)
{
    return aoi_untar_gz_progress(archive, dir, files, progress, ctx);
}

static const char *const shell_env[] = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games", "HOME=/root", "USER=root", "LOGNAME=root",
    "SHELL=/bin/bash", "TERM=xterm-256color", "COLORTERM=truecolor", "LANG=C.UTF-8",
    "PROMPT_COMMAND=history -a",                                   /* the history survives the app being closed */
    "DEBCONF_NOWARNINGS=yes", NULL };

static void *sess_main(void *arg)
{
    lx_session *s = arg;
    for (;;) {
        enum aoi_stop st = aoi_proc_run(s->p, 0);
        if (st == AOI_RUN && !s->p->stop_request) continue;
        break;
    }
    s->running = 0;
    if (!s->closing && s->exited) s->exited(s->ctx);
    aoi_proc_free(s->p);                                           /* (its memory goes back now) */
    free(s->p);
    s->p = NULL;
    return NULL;
}

lx_session *lx_session_start(const char *root, const char *snap, int cols, int rows,
                             void (*out)(void *ctx, const char *s, size_t n),
                             void (*exited)(void *ctx), void *ctx, int *resumed)
{
    lx_session *s = calloc(1, sizeof *s);
    pthread_t th;
    pthread_attr_t at;
    const char *argv[] = { "/bin/bash", "-l", NULL };
    const char *env[sizeof shell_env / sizeof *shell_env];
    char bash[1100];
    struct stat bs;
    size_t k;
    if (!root || !*root) root = g_root;
    for (k = 0; k < sizeof shell_env / sizeof *shell_env; k++) env[k] = shell_env[k];
    snprintf(bash, sizeof bash, "%s/bin/bash", root);
    if (lstat(bash, &bs)) {                                        /* no bash (Alpine): its own shell */
        argv[0] = "/bin/sh";
        for (k = 0; env[k]; k++) if (!strncmp(env[k], "SHELL=", 6)) env[k] = "SHELL=/bin/sh";
    }
    if (!s || !(s->p = calloc(1, sizeof *s->p))) { free(s); return NULL; }
    s->out = out; s->exited = exited; s->ctx = ctx;
    snprintf(s->snap, sizeof s->snap, "%s", snap ? snap : "");
    if (!(s->tty = aoi_tty_new(out, ctx, cols, rows))) { free(s->p); free(s); return NULL; }
    *resumed = 0;
    if (snap && *snap && aoi_snap_this_build(snap) && !aoi_snap_load(s->p, snap, root, NULL)) {
        aoi_proc_attach_tty_to(s->p, s->tty);                     /* its terminal is this session's now */
        {   /* a shell is saved only while it waits at its prompt, in readline, which had the
             * terminal in character mode; the new terminal starts in line mode, so keys showed
             * as ^[[D until Enter made bash set it again */
            uint8_t tio[44];
            uint32_t lflag;
            aoi_tty_get(s->tty, tio);
            memcpy(&lflag, tio + 12, 4);
            lflag &= ~(uint32_t)(0x2 | 0x8 | 0x40);                /* ICANON, ECHO, ECHONL */
            memcpy(tio + 12, &lflag, 4);
            tio[17 + 6] = 1; tio[17 + 5] = 0;                      /* VMIN 1, VTIME 0 */
            aoi_tty_set(s->tty, tio, 36, 0);
        }
        *resumed = 1;
    } else {
        memset(s->p, 0, sizeof *s->p);
        if (aoi_proc_exec(s->p, root, argv[0], 2, argv, env)) { free(s->p); free(s); return NULL; }
        aoi_proc_linux(s->p, "/root");
        aoi_proc_attach_tty_to(s->p, s->tty);
    }
    if (g_trace) { s->p->trace = g_trace; s->p->log = g_trace; s->p->trace_shared = 1; }
    s->running = 1;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 8u << 20);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, sess_main, s)) { pthread_attr_destroy(&at); return NULL; }
    pthread_attr_destroy(&at);
    return s;
}

lx_session *lx_session_run(const char *root, const char *command,
                           void (*out)(void *ctx, const char *s, size_t n), void (*exited)(void *ctx), void *ctx)
{
    lx_session *s = calloc(1, sizeof *s);
    pthread_t th;
    pthread_attr_t at;
    const char *argv[] = { "/bin/bash", "-lc", command, NULL };
    const char *env[sizeof shell_env / sizeof *shell_env + 1];
    char bash[1100];
    struct stat bs;
    size_t k;
    if (!root || !*root) root = g_root;
    for (k = 0; k < sizeof shell_env / sizeof *shell_env; k++) env[k] = shell_env[k];
    env[k - 1] = "LXTERM_QUIET=1";                                 /* (no welcome text in a command's output) */
    env[k] = NULL;
    snprintf(bash, sizeof bash, "%s/bin/bash", root);
    if (lstat(bash, &bs)) {
        argv[0] = "/bin/sh";
        for (k = 0; env[k]; k++) if (!strncmp(env[k], "SHELL=", 6)) env[k] = "SHELL=/bin/sh";
    }
    if (!s || !(s->p = calloc(1, sizeof *s->p))) { free(s); return NULL; }
    s->out = out; s->exited = exited; s->ctx = ctx;
    if (!(s->tty = aoi_tty_new(out, ctx, 120, 40))) { free(s->p); free(s); return NULL; }
    {   /* plain text out: no \r added before \n (OPOST off) */
        uint8_t tio[44];
        uint32_t of;
        aoi_tty_get(s->tty, tio);
        memcpy(&of, tio + 4, 4); of &= ~(uint32_t)1; memcpy(tio + 4, &of, 4);
        aoi_tty_set(s->tty, tio, 36, 0);
    }
    if (aoi_proc_exec(s->p, root, argv[0], 3, argv, env)) { free(s->p); free(s); return NULL; }
    aoi_proc_linux(s->p, "/root");
    aoi_proc_attach_tty_to(s->p, s->tty);
    s->running = 1;
    pthread_attr_init(&at);
    pthread_attr_setstacksize(&at, 8u << 20);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, sess_main, s)) { pthread_attr_destroy(&at); return NULL; }
    pthread_attr_destroy(&at);
    return s;
}

void lx_session_input(lx_session *s, const char *b, size_t n) { if (s && s->tty) aoi_tty_input(s->tty, b, n); }
void lx_session_resize(lx_session *s, int cols, int rows) { if (s && s->tty && cols > 0 && rows > 0) aoi_tty_resize(s->tty, cols, rows); }

int lx_session_save(lx_session *s)
{
    struct stat st;
    time_t before = time(NULL);
    int i;
    if (!s || !s->running || !s->snap[0]) return -1;
    if (aoi_proc_children(s->p) || s->p->stopped) return 1;       /* a program runs in it: not now */
    snprintf(s->p->snap_path, sizeof s->p->snap_path, "%s", s->snap);
    s->p->snap_request = 1;
    for (i = 0; i < 400 && s->p->snap_path[0]; i++) usleep(10000);
    if (s->p->snap_path[0]) return 1;
    return !stat(s->snap, &st) && st.st_mtime >= before - 1 ? 0 : -1;
}

void lx_session_title(lx_session *s, char *out, size_t n)
{
    if (!s || !s->tty || aoi_proc_name_of_pgrp(aoi_tty_fg(s->tty), out, n)) snprintf(out, n, "bash");
}

void lx_session_close(lx_session *s)
{
    if (!s) return;
    s->closing = 1;
    if (s->running && s->p) {
        aoi_proc_kill_session(s->p->sid, 9);
        s->p->stop_request = 1;
    }
}
