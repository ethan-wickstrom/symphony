/* Compile the exact production helper against a fake public sysctl boundary.
 * Rename unrelated externals so the fixture can link beside the real library. */
#define sysctl fixture_sysctl
#define caml_eio_posix_wait_exit fixture_wait_exit
#define caml_eio_posix_zombie_only fixture_zombie_only
#include "eio_group_stubs.c"
#undef sysctl

static int scenario;

int fixture_sysctl(int *name, u_int count, void *buffer, size_t *bytes,
                   void *new_buffer, size_t new_bytes) {
  (void)name;
  (void)count;
  (void)new_buffer;
  (void)new_bytes;
  struct kinfo_proc *processes = buffer;
  memset(buffer, 0, *bytes);
  switch (scenario) {
    case 0: *bytes = 0; return 0;
    case 1: processes[0].kp_proc.p_stat = SZOMB; *bytes = sizeof(*processes); return 0;
    case 2: processes[0].kp_proc.p_stat = SRUN; *bytes = sizeof(*processes); return 0;
    case 3: errno = EPERM; return -1;
    case 4: *bytes = 1; return 0;
    case 5: return 0;
    case 6: (*bytes)++; return 0;
    case 7:
      processes[0].kp_proc.p_stat = SRUN;
      processes[0].kp_proc.p_flag = P_WEXIT;
      *bytes = sizeof(*processes);
      return 0;
    default: errno = EINVAL; return -1;
  }
}

CAMLprim value symphony_group_controls(value unit) {
  (void)unit;
  const int expected[] = {1, 1, 0, 0, 0, 0, 0, 0};
  for (scenario = 0; scenario < (int)(sizeof(expected) / sizeof(expected[0])); scenario++) {
    if (zombie_only(42) != expected[scenario]) {
      return Val_false;
    }
  }
  return Val_true;
}
