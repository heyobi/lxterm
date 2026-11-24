/* The bridge between the SwiftUI app and the core: Debian sessions, each a shell on a
 * terminal (core/tty.c) running in a host thread of its own, saved to and resumed from
 * snapshots (core/snap.c). Plain C so Swift can call it through the bridging header. */
#ifndef LX_ENGINE_H
#define LX_ENGINE_H

#include <stddef.h>

typedef struct lx_session lx_session;

/* Debugging: every syscall of every process to this file (call before any session). */
void lx_engine_trace(const char *path);

/* Once per launch: the root (unpacked), DNS servers for it, the fd limit. */
void lx_engine_init(const char *root);
/* The guest's /root/Files is `host` (the folder shared with the Files app). */
void lx_engine_bind_files(const char *host);

/* Unpacks a .tar.gz root into dir. NULL, or what went wrong; *files counts regular files,
 * progress (0..1, from the archive's bytes read) is called now and then. */
const char *lx_unpack(const char *archive, const char *dir, unsigned long *files,
                      void (*progress)(void *ctx, double f), void *ctx);

/* Starts a session: resumes the shell from snap (if it exists and is from this build),
 * else starts /bin/bash -l. out gets the terminal's output (any thread); exited is called
 * when the shell ends. *resumed tells which happened. NULL on failure. */
lx_session *lx_session_start(const char *snap, int cols, int rows,
                             void (*out)(void *ctx, const char *s, size_t n),
                             void (*exited)(void *ctx), void *ctx, int *resumed);
void lx_session_input(lx_session *s, const char *b, size_t n);
void lx_session_resize(lx_session *s, int cols, int rows);
/* Saves the shell to its snapshot file (waits up to ~4 s): 0 saved, 1 not now (a program
 * is running in it, or it is busy), -1 failed. */
int lx_session_save(lx_session *s);
/* The session's foreground program name ("bash", "python3"...) for its tab. */
void lx_session_title(lx_session *s, char *out, size_t n);
/* Ends the session (its processes are killed). */
void lx_session_close(lx_session *s);

#endif
