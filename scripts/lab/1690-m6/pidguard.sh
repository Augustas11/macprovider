# Sourced by rig.sh and serve.sh. A lab PID file records the identity of the
# process the rig started: pid, start time, uid, the full command line, and
# the $LAB it belongs to. A process is signalled only while every one of those
# still matches, so a dead lab process whose PID was reused (possibly by the
# live provider) is never signalled. A mismatching PID file is stale: it is
# removed and nothing is signalled.
#
# Hard denylist: a command line naming the live provider install or its
# config is never recorded and never signalled, whatever the PID file says.
PIDGUARD_DENY=("/Users/a1/macprovider/" ".config/macprovider/config.yaml")

pg_ps() { ps -ww -o "$2=" -p "$1" 2>/dev/null; } # pid field

pg_denied() {
  local d
  for d in "${PIDGUARD_DENY[@]}"; do [[ "$1" == *"$d"* ]] && return 0; done
  return 1
}

pg_get() { sed -n "s/^$2=//p" "$1" | head -n 1; } # pidfile key

# pg_record PIDFILE PID: capture identity once the launcher (nohup, cli.sh)
# has exec'd into the lab process and the command line is stable.
pg_record() {
  local pidf=$1 pid=$2 cmd prev="" lstart uid
  rm -f "$pidf"
  for _ in $(seq 1 50); do
    cmd=$(pg_ps "$pid" command) || cmd=""
    [[ -n "$cmd" ]] || { echo "pidguard: pid $pid exited before its identity was recorded" >&2; return 1; }
    if [[ "$cmd" != nohup\ * && "$cmd" != *"/cli.sh "* && "$cmd" == "$prev" ]]; then break; fi
    prev=$cmd
    sleep 0.1
  done
  if [[ "$cmd" != "$prev" || "$cmd" == nohup\ * || "$cmd" == *"/cli.sh "* ]]; then
    echo "pidguard: pid $pid command line never settled; not recording it" >&2
    return 1
  fi
  if pg_denied "$cmd" || [[ "$cmd" != *"$LAB/"* ]]; then
    echo "pidguard: pid $pid is not a $LAB process; not recording it: $cmd" >&2
    return 1
  fi
  lstart=$(pg_ps "$pid" lstart) && uid=$(pg_ps "$pid" uid) || { echo "pidguard: pid $pid exited" >&2; return 1; }
  (umask 077; printf 'pid=%s\nlstart=%s\nuid=%s\nlab=%s\ncommand=%s\n' "$pid" "$lstart" "${uid// /}" "$LAB" "$cmd" >"$pidf")
}

# pg_verify PIDFILE: 0 only if the recorded process is alive and is still
# exactly the one recorded. Prints the pid on success.
pg_verify() {
  local pidf=$1 pid cmd
  [[ -f "$pidf" ]] || return 1
  pid=$(pg_get "$pidf" pid)
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]] || return 1
  [[ "$(pg_get "$pidf" lab)" == "$LAB" ]] || return 1
  cmd=$(pg_ps "$pid" command) || return 1
  [[ -n "$cmd" && "$cmd" == "$(pg_get "$pidf" command)" ]] || return 1
  pg_denied "$cmd" && return 1
  [[ "$cmd" == *"$LAB/"* ]] || return 1
  [[ "$(pg_ps "$pid" lstart)" == "$(pg_get "$pidf" lstart)" ]] || return 1
  local uid; uid=$(pg_ps "$pid" uid)
  [[ "${uid// /}" == "$(pg_get "$pidf" uid)" ]] || return 1
  echo "$pid"
}

# pg_stop PIDFILE WAIT_STEPS STEP_SECONDS: TERM, then KILL only if the
# identity still matches after the grace period.
pg_stop() {
  local pidf=$1 steps=$2 step=$3 pid
  [[ -f "$pidf" ]] || return 0
  if ! pid=$(pg_verify "$pidf"); then
    echo "pidguard: $pidf is stale or does not match its process; removed, nothing signalled" >&2
    rm -f "$pidf"
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 "$steps"); do pg_verify "$pidf" >/dev/null || break; sleep "$step"; done
  if pid=$(pg_verify "$pidf"); then kill -KILL "$pid" 2>/dev/null || true; fi
  rm -f "$pidf"
}
