# shellcheck shell=bash
# mysql-first-boot.sh -- the first boot of the MySQL datadir, run in the
# mysql-first-boot init container of mysql-deployment.yaml.
#
# bash SOURCES this file through BASH_ENV before it runs the image's own
# docker-entrypoint.sh, so the image's ENTRYPOINT and CMD run unchanged: the
# entrypoint initialises an empty datadir exactly as it would in mysql-client,
# but here no probe can kill it part-way. This file adds three things:
#
#   1. The datadir's two markers:
#        .tracebloc-init-started   written just before a first boot begins
#        .tracebloc-init-complete  written once that boot's temporary server
#                                  has shut down cleanly
#   2. A first boot that never finished (started, not complete) is reset and
#      initialised again, but ONLY when the datadir holds nothing except what
#      initialisation itself writes. Anything else stops the reset, loudly.
#   3. The init container exits once the datadir is initialised, instead of
#      running the server: mysql-client starts it.
#
# A datadir with neither marker was written before the markers existed (or by a
# migration or a restore), and is never touched. Fail closed: when this file
# cannot tell, it leaves the datadir as it is and says so.

# Only the container's own entrypoint, PID 1. Any other bash here returns.
[ "$$" = 1 ] || return 0
unset BASH_ENV

tb_d=/var/lib/mysql
tb_started="$tb_d/.tracebloc-init-started"
tb_complete="$tb_d/.tracebloc-init-complete"

tb_say() { printf 'mysql-first-boot: %s\n' "$*"; }

# The installer reads this line (summary.sh, _mysql_first_boot_verdict).
tb_verdict() { printf 'TRACEBLOC_MYSQL_FIRST_BOOT=%s user_data=%s\n' "$1" "$2"; }

# tb_scan -- sorts every top-level datadir entry, the markers and lost+found
# aside, into tb_entries (all of them) and tb_unknown (any that initialisation
# does not write, or that holds rows: user data, or something this file cannot
# vouch for). Space-separated; an entry name with a space is itself unknown.
tb_scan() {
  tb_entries=""; tb_unknown=""
  local e n restore
  restore="$(shopt -p dotglob nullglob)"
  shopt -s dotglob nullglob
  for e in "$tb_d"/*; do
    n="${e##*/}"
    case "$n" in
      .tracebloc-init-started|.tracebloc-init-complete|lost+found) continue ;;
    esac
    tb_entries="$tb_entries $n"
    if [ -L "$e" ]; then tb_unknown="$tb_unknown $n"; continue; fi
    case "$n" in
      *[[:space:]]*) tb_unknown="$tb_unknown $n" ;;
      mysql|sys|performance_schema|'#innodb_redo'|'#innodb_temp')
        [ -d "$e" ] || tb_unknown="$tb_unknown $n" ;;
      ibdata[0-9]*|ibtmp[0-9]*|mysql.ibd|undo_[0-9][0-9][0-9]|'#ib_'*.dblwr|auto.cnf|*.pem|mysql_upgrade_history|binlog.index|binlog.[0-9]*|ib_buffer_pool|ib_logfile[0-9]*|*.pid|mysql.sock|mysql.sock.lock|mysqlx.sock|mysqlx.sock.lock)
        [ -f "$e" ] || [ -S "$e" ] || tb_unknown="$tb_unknown $n" ;;
      *)
        # The image's MYSQL_DATABASE schema, created during initialisation:
        # allowed only while it holds no table at all.
        if [ -n "${MYSQL_DATABASE:-}" ] && [ "$n" = "$MYSQL_DATABASE" ] && [ -d "$e" ] \
          && [ -z "$(ls -A "$e" 2>/dev/null)" ] && [ -r "$e" ]; then
          :
        else
          tb_unknown="$tb_unknown $n"
        fi ;;
    esac
  done
  eval "$restore"
}

# tb_redo_unfinished -- InnoDB's redo log says the datadir's creation never finished,
# which MySQL refuses at every start (MY-012960): no redo file at all, or a redo
# file (8.0.30+ #ib_redoN) whose header still carries LOG_HEADER_FLAG_NOT_INITIALIZED
# (bit 3 of the big-endian flags word at byte 48). A short or unreadable header is
# "cannot tell", which is not "unfinished".
tb_redo_unfinished() {
  local f b any=""
  [ -f "$tb_d/ib_logfile0" ] && return 1
  for f in "$tb_d/#innodb_redo/#ib_redo"[0-9]*; do
    case "$f" in *'*'|*_tmp) continue ;; esac
    [ -f "$f" ] || continue
    any=1
    b="$(od -A n -t u1 -j 51 -N 1 "$f" 2>/dev/null | tr -d ' ')"
    case "$b" in ''|*[!0-9]*) continue ;; esac
    [ $(( b & 8 )) -eq 0 ] || return 0
  done
  [ -z "$any" ]
}

# The markers are written for MySQL 8.x only: 8.x initialises a datadir that holds
# dot-files; 5.7 refuses one with files in it. Any other engine keeps the entrypoint's
# own first boot, in mysql-client, as before.
case "${MYSQL_MAJOR:-}" in
  8.*) ;;
  *)
    tb_say "MySQL ${MYSQL_MAJOR:-of an unknown version}: first boot left to mysql-client"
    exit 0 ;;
esac

if [ ! -d "$tb_d" ] || [ ! -w "$tb_d" ]; then
  tb_say "WARNING: cannot write $tb_d, so nothing here is checked or changed"
  exit 0
fi

if [ -e "$tb_complete" ]; then
  if [ -d "$tb_d/mysql" ]; then
    tb_say "datadir initialised"
    exit 0
  fi
  # Marked complete, but its system schema is gone: no longer an initialised datadir.
  # It goes back to an unfinished first boot, which the checks below reset only when empty of data.
  tb_say "WARNING: the datadir is marked initialised but has no mysql/ system schema; checking it as an unfinished first boot"
  rm -f -- "$tb_complete"
  [ -e "$tb_started" ] || date -u '+%Y-%m-%dT%H:%M:%SZ' > "$tb_started"
fi

tb_scan
if [ -n "$tb_entries" ]; then
  if [ ! -e "$tb_started" ]; then
    # Not a first boot this chart began: never reset.
    if [ -d "$tb_d/mysql" ] && tb_redo_unfinished; then
      if [ -n "$tb_unknown" ]; then tb_ud=present; else tb_ud=none; fi
      tb_say "WARNING: InnoDB's redo log says this datadir was never fully created, so MySQL cannot start it (MY-012960):"
      tb_say "its first start was stopped before it finished. It is NOT reset here, because it"
      tb_say "has no first-boot marker, so this init container did not create it."
      tb_verdict never-served "$tb_ud"
    else
      tb_say "existing datadir from before the first-boot markers: kept as it is"
    fi
    exit 0
  fi
  if [ -n "$tb_unknown" ]; then
    tb_say "WARNING: the first start of this datadir never finished, but it is NOT reset:"
    tb_say "it holds entries initialisation does not write, which may be data:${tb_unknown}"
    tb_say "mysql-client starts on it as it is. Remove them by hand to let it be reset."
    tb_verdict incomplete present
    exit 0
  fi
  tb_say "the first start of this datadir never finished, and it holds only what"
  tb_say "initialisation writes (${tb_entries# }): resetting it and initialising again"
  restore="$(shopt -p dotglob nullglob)"
  shopt -s dotglob nullglob
  # The started marker stays until the datadir is empty, so a reset cut short is retried.
  for e in "$tb_d"/*; do
    case "${e##*/}" in lost+found|.tracebloc-init-started) continue ;; esac
    rm -rf -- "$e" || {
      tb_say "WARNING: could not remove ${e##*/}; the reset stopped part-way and runs again on the next start"
      exit 1
    }
  done
  eval "$restore"
fi

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$tb_started"
tb_say "empty datadir: initialising it ($(date -u '+%H:%M:%S'))"

# A first boot takes seconds; one that does not says so every tb_tick_s, so a
# stall shows in kubectl logs (the installer names one past five minutes).
tb_tick_s=30
( t=0; while sleep "$tb_tick_s"; do t=$((t + tb_tick_s)); tb_say "still initialising after ${t}s"; done ) &
tb_ticker=$!
disown "$tb_ticker" 2>/dev/null || :   # no "Terminated" job notice when it is stopped

# On a failed initialisation the reason is in the error log, which kubectl logs
# does not show.
tb_on_exit() {
  local rc=$?
  kill "$tb_ticker" 2>/dev/null || :
  if [ "$rc" != 0 ]; then
    tb_say "initialisation failed (exit $rc). The error log ends with:"
    tail -n 30 /var/log/mysql/error.log 2>/dev/null || :
  fi
}
trap tb_on_exit EXIT

# The entrypoint ends in `exec "$@"`, which would start the server here. Once its
# temporary server has stopped cleanly the datadir is initialised: mark it and
# exit, so mysql-client starts the server.
exec() {
  if [ "${1:-}" = mysqld ]; then
    kill "$tb_ticker" 2>/dev/null || :
    if [ -z "${DATABASE_ALREADY_EXISTS:-}" ] && [ -d "$tb_d/mysql" ]; then
      date -u '+%Y-%m-%dT%H:%M:%SZ' > "$tb_complete"
      tb_say "datadir initialised ($(date -u '+%H:%M:%S')); mysql-client starts the server"
    else
      tb_say "WARNING: the entrypoint found an existing datadir; leaving its first start to mysql-client"
    fi
    builtin exit 0
  fi
  builtin exec "$@"
}
