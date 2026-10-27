# shellcheck shell=bash
# stand-in.sh: give a test's fake program the process name the real one has. Source it from a
# bash test:
#
#   . "$here/lib/stand-in.sh"
#   stand_in_build "$tmp/bin" claude               # makes $tmp/bin/claude
#   tsb new-session -d "exec $tmp/bin/claude python3 fake_tui.py"   # tmux reads it as "claude"
#
# Why: tmux names a pane's command after the leader of its foreground process group. Linux tmux
# reads that process's argv[0], so `exec -a claude python3 fake.py` works there; macOS tmux reads
# the name of its executable file, so a script shows as its interpreter ("Python", "bash"). The
# stand-in is a compiled launcher named for the program: it runs its arguments as a child and stays
# the group's leader, so the pane reads right on both. TERM and HUP sent to it go to the child.
# Run it with `exec` so it replaces the pane's shell instead of running under it.
# Without a C compiler it is a bash script using exec -a, which is right on Linux only.

# stand_in_build DIR NAME...: one stand-in per NAME in DIR.
stand_in_build() {
  local dir="$1" name built
  shift
  mkdir -p "$dir"
  built="$dir/.stand-in"
  if [[ ! -x "$built" ]]; then
    if command -v cc >/dev/null 2>&1; then
      cat > "$dir/.stand-in.c" <<'C'
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
static pid_t child;
static void pass(int sig) { if (child > 0) kill(child, sig); }
int main(int argc, char **argv) {
    int st;
    if (argc < 2) return 2;
    signal(SIGTERM, pass);
    signal(SIGHUP, pass);
    child = fork();
    if (child < 0) return 127;
    if (child == 0) { execvp(argv[1], argv + 1); _exit(127); }
    while (waitpid(child, &st, 0) < 0) {}
    return WIFEXITED(st) ? WEXITSTATUS(st) : 128 + WTERMSIG(st);
}
C
      cc -o "$built" "$dir/.stand-in.c" || return 1
    else
      built=""
    fi
  fi
  for name in "$@"; do
    if [[ -n "$built" ]]; then
      cp "$built" "$dir/$name"
    else
      printf '#!/usr/bin/env bash\nexec -a %q "$@"\n' "$name" > "$dir/$name"
      chmod +x "$dir/$name"
    fi
  done
}
