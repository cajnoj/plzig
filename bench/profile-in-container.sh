#!/bin/bash
# Profiling mode of bench/run.sh (--profile "QUERY"): runs as root in the
# benchmark container.  The driver (as postgres) sets up the cluster, writes
# the pid of the backend that will run QUERY, and waits; perf attaches to
# that backend (user-space cycles only), the driver runs QUERY, perf stops.
set -u
mkdir -p /tmp/out
chown postgres /tmp/out
gosu postgres python3 /bench/driver.py "$@" &
drv=$!
while [ ! -f /tmp/out/backend.pid ] && kill -0 $drv 2>/dev/null; do sleep 0.2; done
if [ ! -f /tmp/out/backend.pid ]; then wait $drv; exit 1; fi
perf record -e cycles:u -F 4999 -g -p "$(cat /tmp/out/backend.pid)" \
    -o /tmp/out/perf.data >/tmp/out/perf.log 2>&1 &
pp=$!
sleep 1
touch /tmp/out/go
while [ ! -f /tmp/out/done ] && kill -0 $drv 2>/dev/null; do sleep 0.2; done
kill -INT $pp
wait $pp
touch /tmp/out/stopped
wait $drv
rc=$?
{
    cat /tmp/out/profile.txt 2>/dev/null
    echo
    perf report -i /tmp/out/perf.data --stdio --no-children --sort dso,symbol \
        -g none --percent-limit 0.3 2>/dev/null | grep -v '^$'
} > /tmp/out/perf-report.txt
head -60 /tmp/out/perf-report.txt
rm -f /tmp/out/go /tmp/out/done /tmp/out/stopped
chown -R postgres /tmp/out
exit $rc
