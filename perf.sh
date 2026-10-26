#!/bin/sh
# Idle budget: launches the built app (./build.sh first), waits 5 s, then measures 30 s with the panel closed.
# Fails if the memory footprint or average CPU goes over budget. Shows a second menu bar icon while it runs.
set -e
cd "$(dirname "$0")"
max_mb=25 max_cpu=1.0
OpenMem.app/Contents/MacOS/OpenMem >/dev/null 2>&1 & pid=$!
trap 'kill $pid 2>/dev/null' EXIT
cpu() { ps -o cputime= -p $pid | awk -F'[:.]' '{ print (NF==3) ? $1*60+$2+$3/100 : $1*3600+$2*60+$3+$4/100 }'; }
sleep 5; c0=$(cpu); sleep 30; c1=$(cpu)
mb=$(footprint -p $pid | awk '/phys_footprint:/{ v=$2; if ($3 ~ /KB/) v/=1024; if ($3 ~ /GB/) v*=1024; print int(v+0.5); exit }')
pct=$(echo "scale=2; ($c1 - $c0) * 100 / 30" | bc)
echo "idle: footprint ${mb} MB (budget ${max_mb}), cpu ${pct}% (budget ${max_cpu}%)"
[ "$mb" -le $max_mb ] && [ "$(echo "$pct <= $max_cpu" | bc)" = 1 ] || { echo "over budget"; exit 1; }
echo "within budget"
