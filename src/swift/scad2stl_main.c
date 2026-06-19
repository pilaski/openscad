/*
 * scad2stl_main.c — minimal C driver exercising the openscad_kernel C ABI.
 * Proves the ABI works without a Swift toolchain. Usage:
 *   scad2stl_c <input.scad> <output.stl> [fn]
 */
#include "openscad_kernel.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
  if (argc < 3) {
    fprintf(stderr, "usage: %s <input.scad> <output.stl> [fn]\n", argv[0]);
    return 2;
  }
  double fn = (argc >= 4) ? atof(argv[3]) : 0.0;

  osk_init(argv[0]);
  fprintf(stderr, "backend: %s\n", osk_backend());

  char *err = NULL;
  int rc = osk_render_file(argv[1], argv[2], -1 /* infer from ext */, fn, &err);
  if (rc != 0) {
    fprintf(stderr, "render failed (rc=%d): %s\n", rc, err ? err : "(no message)");
    osk_string_free(err);
    return 1;
  }
  fprintf(stderr, "wrote %s\n", argv[2]);
  return 0;
}
