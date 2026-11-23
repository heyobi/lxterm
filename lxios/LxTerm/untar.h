#ifndef AOI_UNTAR_H
#define AOI_UNTAR_H
/* Unpacks archive (a .tar.gz) into dest. NULL, or what went wrong; *nfiles: regular files. */
const char *aoi_untar_gz(const char *archive, const char *dest, unsigned long *nfiles);
/* The same, calling progress(ctx, 0..1) now and then (compressed bytes read / size). */
const char *aoi_untar_gz_progress(const char *archive, const char *dest, unsigned long *nfiles,
                                  void (*progress)(void *ctx, double f), void *ctx);
#endif
