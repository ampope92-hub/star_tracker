#!/bin/bash

# Verifier entrypoint. Runs in the verifier container, not the agent's, and sees only the paths
# declared in `artifacts`. Everything it needs is baked into tests/Dockerfile; nothing is fetched
# here. It builds the collected Swift once and runs the tracker twice, each time against a camera
# head it starts from the copy in this image: the shipped pass on another address and port, then
# a held-back pass from another unit, reached by host name.

set -uo pipefail
# The image's working directory is the tree the build below deletes and recreates.
cd /
mkdir -p /logs/verifier
echo 0 > /logs/verifier/reward.txt
exec 2>&1

# Root runs this script and later runs pytest, after agent-authored code has run as the build
# user. Every directory on PATH has to be one the build user cannot write to, so PATH is pinned
# and each entry is checked before anything untrusted runs.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
hash -r
for d in ${PATH//:/ }; do
  real="$(/usr/bin/readlink -f "$d" 2>/dev/null)" || continue
  [ -d "$real" ] || continue
  owner="$(/usr/bin/stat -c %u "$real")"
  mode="$(/usr/bin/stat -c %a "$real")"
  if [ "$owner" != "0" ] || [ $(( 8#$mode & 8#022 )) -ne 0 ]; then
    echo "FATAL: $d (-> $real) is on root's PATH but is owner $owner mode $mode."
    echo 0 > /logs/verifier/reward.txt
    exit 0
  fi
done
echo "every directory on root's PATH is root-owned and closed to writing by anyone else"

SWIFTC=/usr/bin/swiftc
PY=/usr/bin/python3
if [ ! -x "$SWIFTC" ] || [ ! -x "$PY" ]; then
  echo "FATAL: the Swift toolchain or the camera head's interpreter is missing"
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

/usr/bin/install -d -m 700 -o root -g root /opt/run
/usr/bin/install -d -m 755 -o root -g root /opt/stage

as_runner() {
  setpriv --clear-groups --no-new-privs --reuid runner --regid runner "$@"
}

# The held-back run reaches its camera head by name. README.md says CAMERA_HOST can be a host
# name or an address, so a tracker that only takes a dotted quad is reading more into it.
CAMERA_BY_NAME=stu-c.bench.internal
printf '%s\t%s\n' 127.0.0.4 "$CAMERA_BY_NAME" >> /etc/hosts
if ! /usr/bin/getent hosts "$CAMERA_BY_NAME" >/dev/null 2>&1; then
  echo "FATAL: $CAMERA_BY_NAME does not resolve in this container"
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi

# Close the verifier's own code, the passes, the true attitudes, the camera head and the reward
# directory to the build user before anything untrusted runs, and prove it. `ls` needs read
# permission on the directory itself, which is the right probe.
chmod 700 /tests /logs/verifier /opt/truth /opt/camera /opt/run 2>/dev/null || true
if as_runner bash -c 'test -r /tests/test_outputs.py || ls /opt/truth || ls /opt/camera || ls /opt/run || ls /logs/verifier' >/dev/null 2>&1; then
  echo "FATAL: /tests, the passes, the camera head, the run directory or the reward directory is reachable by the build user."
  echo 0 > /logs/verifier/reward.txt
  exit 0
fi
echo "verifier files closed to the unprivileged build user"

# What is compiled is Swift source and nothing else, by construction: the regular .swift files
# directly under /app/tracker are copied into a root-owned pristine directory and rebuilt from
# there with the command the instruction states. A link, a subdirectory, a package manifest or
# anything that is not a .swift file never reaches the compiler, and the toolchain has no
# Foundation module to import.
rm -rf /opt/src_pristine
/usr/bin/install -d -m 700 -o root -g root /opt/src_pristine
for f in /app/tracker/*.swift; do
  if [ -f "$f" ] && [ ! -L "$f" ]; then /usr/bin/cp --no-dereference "$f" /opt/src_pristine/; fi
done
echo "collected .swift files: $(ls /opt/src_pristine | wc -l)"

rm -rf /app/tracker
/usr/bin/install -d -o runner -g runner -m 755 /app/tracker
cp /opt/src_pristine/*.swift /app/tracker/ 2>/dev/null || true
chown -R runner:runner /app/tracker
/usr/bin/find /app/tracker -type f -exec /usr/bin/touch {} +

# Interpreters closed to the build user while the Swift compiles: the build has no business
# running them. Root is unaffected.
INTERP="$(for t in python3 python3.10 pip pip3 perl awk mawk; do
            p="$(command -v "$t" 2>/dev/null)" && readlink -f "$p"; done | sort -u)"
close_interp() { for f in $INTERP; do /usr/bin/chmod 750 "$f" 2>/dev/null || true; done; }
open_interp()  { for f in $INTERP; do /usr/bin/chmod 755 "$f" 2>/dev/null || true; done; }
trap 'open_interp' EXIT

echo ok > /opt/run/build_check.txt
close_interp
if ls /app/tracker/*.swift >/dev/null 2>&1; then
  setsid /usr/bin/timeout --signal=KILL 600 \
    setpriv --clear-groups --no-new-privs --reuid runner --regid runner \
    env -i -C /app/tracker HOME=/home/runner TMPDIR=/tmp PATH=/usr/bin:/bin \
        /bin/bash -c "exec $SWIFTC -O -static-stdlib -o /app/tracker/tracker /app/tracker/*.swift" &
  bpid=$!
  wait "$bpid"
  bstatus=$?
  kill -KILL -- -"$bpid" 2>/dev/null || true
else
  echo "no .swift file directly under /app/tracker"
  bstatus=1
fi
echo "swiftc exit status: $bstatus"
open_interp
as_runner bash -c 'kill -9 -1' 2>/dev/null || true
[ "$bstatus" -eq 0 ] || echo failed > /opt/run/build_check.txt
if [ -L /app/tracker/tracker ] || [ ! -f /app/tracker/tracker ]; then
  echo "no regular binary was produced at /app/tracker/tracker"
  echo failed > /opt/run/build_check.txt
  /usr/bin/rm -f /app/tracker/tracker
fi

SERVICE_PID=""
start_camera() {   # $1 pass, $2 address, $3 port, $4 first link, $5 link
  /usr/bin/rm -f /opt/run/ready
  "$PY" /opt/camera/camera.py --data "/opt/truth/$1/pass.txt" --host "$2" --port "$3" \
      --first-link "$4" --link "$5" \
      --ready-file /opt/run/ready --log "/opt/run/camera_$1.log" >> "/opt/run/camera_$1.err" 2>&1 &
  SERVICE_PID=$!
  local i
  for i in $(/usr/bin/seq 1 600); do
    [ -f /opt/run/ready ] && return 0
    /usr/bin/sleep 0.1
  done
  echo "FATAL: the camera head never came up on $2:$3"
  return 1
}

# `kill` is the shell builtin on purpose: a builtin cannot be shadowed by anything on PATH.
stop_camera() {
  [ -n "$SERVICE_PID" ] || return 0
  kill -TERM "$SERVICE_PID" 2>/dev/null || true
  wait "$SERVICE_PID" 2>/dev/null
  SERVICE_PID=""
}

# $1 pass, $2 CAMERA_HOST, $3 CAMERA_PORT. The pass's catalogue is staged in a root-owned
# directory the build user can read. The binary the build produced is started from
# /app/tracker as the build user with a clean environment, a 2 GiB address-space limit, and
# through tool_launch (tests/launch.c) so neither it nor any child can start another program.
# Stdout is captured for grading; stderr goes to this log. The run is killed at the 120 seconds
# the instruction states; the wall time is recorded so a run is only called a timeout when it
# actually reached the limit.
run_tracker() {
  local out="/opt/run/report_$1.txt" pid status t0 t1
  /usr/bin/find /tmp /var/tmp /dev/shm -mindepth 1 -user runner -delete 2>/dev/null || true
  /usr/bin/rm -rf /opt/stage/*
  /usr/bin/install -d -m 755 -o root -g root "/opt/stage/$1"
  /usr/bin/install -m 644 -o root -g root "/opt/truth/$1/catalog.txt" "/opt/stage/$1/catalog.txt"
  t0="$(/usr/bin/date +%s.%N)"
  setsid /usr/bin/timeout --signal=KILL 120 \
    env -i -C /app/tracker HOME=/home/runner PATH=/usr/bin:/bin \
        CAMERA_HOST="$2" CAMERA_PORT="$3" STAR_CATALOG="/opt/stage/$1/catalog.txt" \
      setpriv --clear-groups --no-new-privs --reuid runner --regid runner \
      /usr/bin/prlimit --as=2147483648 -- \
      /usr/local/bin/tool_launch /app/tracker/tracker > "$out" &
  pid=$!
  wait "$pid"
  status=$?
  t1="$(/usr/bin/date +%s.%N)"
  kill -KILL -- -"$pid" 2>/dev/null || true
  as_runner bash -c 'kill -9 -1' 2>/dev/null || true
  /usr/bin/chown root:root "$out" 2>/dev/null || true
  /usr/bin/chmod 600 "$out" 2>/dev/null || true
  echo "$status $t0 $t1" > "/opt/run/status_$1.txt"
  echo "run $1: exit status $status, camera head $2:$3"
}

echo "=== the shipped pass, on another address and port, with other link lengths ==="
if start_camera sample 127.0.0.3 7411 23 1597; then
  run_tracker sample 127.0.0.3 7411
fi
stop_camera

echo "=== a held-back pass from another unit, reached by name ==="
if start_camera hidden 127.0.0.4 7512 61 2389; then
  run_tracker hidden "$CAMERA_BY_NAME" 7512
fi
stop_camera
as_runner bash -c 'kill -9 -1' 2>/dev/null || true
/usr/bin/rm -rf /opt/stage/*

for s in sample hidden; do
  if [ -f "/opt/run/camera_$s.log" ]; then
    echo "$s: $(/usr/bin/grep -c ' OPEN' /opt/run/camera_$s.log) connections, $(/usr/bin/grep -c 'LINK DOWN' /opt/run/camera_$s.log) link drops, $(/usr/bin/grep -c ' EOS' /opt/run/camera_$s.log) end of pass"
  fi
done

# By absolute path, and -I (isolated mode) keeps the working directory and the user site off the
# module path; this Python is 3.10, which has no -P.
"$PY" -I -m pytest -o cache_dir=/tmp/pytest_cache -p no:cacheprovider \
  --ctrf /logs/verifier/ctrf.json /tests/test_outputs.py -rA
if [ "$?" -eq 0 ]; then echo 1 > /logs/verifier/reward.txt; else echo 0 > /logs/verifier/reward.txt; fi
