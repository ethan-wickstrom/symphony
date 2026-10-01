/* Observe child exit without reaping, so its PID remains reserved until the
 * process-group owner sends its final signal. Existing Eio code still forks. */
#define CAML_INTERNALS
#include "primitives.h"

#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <string.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <sys/proc.h>
#endif

#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#define TAG_EXITED 0
#define TAG_SIGNALED 1

#ifdef __APPLE__
/* Bound temporary storage. A larger or changing snapshot is uncertain and
 * preserves the original permission error; it is never treated as empty. */
#define GROUP_QUERY_CAPACITY 64

static int zombie_only(pid_t pgid) {
  int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid};
  struct kinfo_proc processes[GROUP_QUERY_CAPACITY];
  size_t bytes = sizeof(processes);

  if (sysctl(mib, sizeof(mib) / sizeof(mib[0]), processes, &bytes, NULL, 0) == -1) {
    return 0;
  }
  if (bytes >= sizeof(processes) || bytes % sizeof(processes[0]) != 0) {
    return 0;
  }
  for (size_t i = 0; i < bytes / sizeof(processes[0]); i++) {
    if (processes[i].kp_proc.p_stat != SZOMB) {
      return 0;
    }
  }
  return 1;
}
#endif

CAMLprim value caml_eio_posix_zombie_only(value v_pgid) {
#ifdef __APPLE__
  return Val_bool(zombie_only(Int_val(v_pgid)));
#else
  (void)v_pgid;
  return Val_false;
#endif
}

CAMLprim value caml_eio_posix_wait_exit(value v_pid) {
  CAMLparam1(v_pid);
  CAMLlocal1(status);
  siginfo_t info;
  pid_t pid = Int_val(v_pid);
  int ret, saved_errno;

  memset(&info, 0, sizeof(info));
  caml_enter_blocking_section();
  do {
    ret = waitid(P_PID, pid, &info, WEXITED | WNOWAIT);
  } while (ret == -1 && errno == EINTR);
  saved_errno = errno;
  caml_leave_blocking_section();
  if (ret == -1) {
    errno = saved_errno;
    caml_uerror("waitid", Nothing);
  }

  switch (info.si_code) {
    case CLD_EXITED:
      status = caml_alloc_small(1, TAG_EXITED);
      Field(status, 0) = Val_int(info.si_status);
      break;
    case CLD_KILLED:
    case CLD_DUMPED:
      status = caml_alloc_small(1, TAG_SIGNALED);
      Field(status, 0) = Val_int(caml_rev_convert_signal_number(info.si_status));
      break;
    default:
      caml_unix_error(EINVAL, "waitid", Nothing);
  }
  CAMLreturn(status);
}
