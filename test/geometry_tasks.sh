#!/usr/bin/env bash
# The geometry stage on dista writes what the sequential one writes, byte for
# byte: every work directory given, forward, and backward with --reverse.
#
#   pixi run -e orca test-geometry-tasks <work_dir>[:<flags>] ...
#
# Flags after a colon are passed to both, comma-separated, e.g. an AV2 log:
#   runs/av2/work/<log>:--proprioception,off,--fit-terrain,on
set -euo pipefail
cd "$(dirname "$0")/.."
out=build/test-geometry-tasks
mkdir -p "$out"
[ $# -gt 0 ] || { echo "usage: $0 <work_dir>[:<flags>] ..." >&2; exit 2; }
fail=0
n=0
for arg in "$@"; do
  work=${arg%%:*}
  flags=()
  [ "$arg" != "$work" ] && IFS=, read -r -a flags <<< "${arg#*:}"
  for rev in off on; do
    n=$((n + 1))
    ./build/refinery "$work" "$out/$n.seq.csv" ${flags[@]+"${flags[@]}"} --reverse $rev > "$out/$n.seq.log"
    ./build/geometry-tasks "$work" "$out/$n.tasks.csv" --workers "${WORKERS:-4}" ${flags[@]+"${flags[@]}"} --reverse $rev > "$out/$n.tasks.log"
    if cmp -s "$out/$n.seq.csv" "$out/$n.tasks.csv"; then
      echo "ok   $work ${flags[*]-} --reverse $rev ($(tail -1 "$out/$n.seq.log" | cut -c1-80) vs $(tail -1 "$out/$n.tasks.log" | cut -c1-80))"
    else
      echo "FAIL $work ${flags[*]-} --reverse $rev: $out/$n.seq.csv and $out/$n.tasks.csv differ"
      fail=1
    fi
  done
done
exit $fail
