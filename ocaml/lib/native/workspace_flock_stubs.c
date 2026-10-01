#include <sys/file.h>
#include <errno.h>

#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

/* One fixed nonblocking operation; the OCaml caller lends the FD for this job. */
CAMLprim value symphony_workspace_flock(value v_fd) {
  CAMLparam1(v_fd);
  int fd = Int_val(v_fd);
  int ret, saved_errno;

  caml_enter_blocking_section();
  do {
    ret = flock(fd, LOCK_EX | LOCK_NB);
  } while (ret == -1 && errno == EINTR);
  saved_errno = errno;
  caml_leave_blocking_section();

  if (ret == 0) {
    CAMLreturn(Val_true);
  }
  if (saved_errno == EAGAIN || saved_errno == EWOULDBLOCK) {
    CAMLreturn(Val_false);
  }
  errno = saved_errno;
  caml_uerror("flock", Nothing);
}
