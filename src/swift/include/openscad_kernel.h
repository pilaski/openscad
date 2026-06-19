/*
 * openscad_kernel.h — stable pure-C ABI over the real OpenSCAD geometry kernel.
 *
 * This is the single contract between Swift (or any C caller) and the headless
 * OpenSCAD renderer. No C++ types cross the boundary, so Swift's standard C
 * interop is sufficient. Same ABI is intended to back the Linux CLI and the iOS
 * framework.
 *
 * Threading: call osk_init() once before any render. The render functions are
 * not guaranteed reentrant (OpenSCAD uses global parser/builtin state); serialize
 * calls or run one renderer per process.
 */
#ifndef OPENSCAD_KERNEL_H
#define OPENSCAD_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Output formats understood by osk_render_*. */
typedef enum {
  OSK_FORMAT_BINSTL = 0,   /* binary STL (default)        */
  OSK_FORMAT_ASCIISTL = 1, /* ASCII STL                   */
  OSK_FORMAT_OFF = 2,      /* Geomview OFF                */
  OSK_FORMAT_OBJ = 3,      /* Wavefront OBJ               */
  OSK_FORMAT_3MF = 4,      /* 3D Manufacturing Format     */
} OSKFormat;

/*
 * Initialize the kernel: register the application/resource path, initialize
 * builtins, the parser, and localization. Idempotent — safe to call repeatedly.
 * application_path may be NULL (a sensible default/argv0 fallback is used).
 */
void osk_init(const char *application_path);

/*
 * A short identifier for the active backend/version, e.g.
 * "OpenSCAD 2026.06.19 (CGAL + Manifold)". Never NULL. Owned by the library.
 */
const char *osk_backend(void);

/*
 * Render a .scad source string to an in-memory buffer.
 *
 *  scad_source   : NUL-terminated OpenSCAD source (UTF-8).
 *  format        : desired output format.
 *  search_path   : extra library search dir for use/include (nullable).
 *  fn_override   : if > 0, forces $fn for the whole model; <= 0 means no override.
 *  out_buffer    : on success, receives a malloc'd buffer with the encoded model.
 *  out_len       : on success, receives the buffer length in bytes.
 *  error_out     : on failure (nonzero return), if non-NULL receives a malloc'd
 *                  UTF-8 message; free it with osk_string_free.
 *
 * Returns 0 on success, nonzero on error.
 */
int osk_render_string(const char *scad_source, OSKFormat format,
                      const char *search_path, double fn_override,
                      uint8_t **out_buffer, size_t *out_len, char **error_out);

/*
 * Render a .scad file to an output file. Format is taken from `format` unless
 * it is negative, in which case it is inferred from the output extension.
 * Returns 0 on success, nonzero on error (see error_out).
 */
int osk_render_file(const char *input_path, const char *output_path, int format,
                    double fn_override, char **error_out);

/* Free a buffer returned by osk_render_string. */
void osk_buffer_free(uint8_t *buffer);

/* Free a string returned via an error_out parameter. */
void osk_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCAD_KERNEL_H */
