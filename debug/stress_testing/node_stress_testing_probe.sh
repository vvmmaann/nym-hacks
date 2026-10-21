#!/usr/bin/env bash
#
# node_stress_testing_probe.sh
#
# Why is this node's stress_testing_score low?
#
# The stress test sends its packets over ONE connection, and nym-node handles
# one connection on ONE core. Single-core speed is the binding constraint -
# core count and RAM are not. This probe measures the things that actually
# predict the score:
#
#   clock speed      - strongest single predictor across the fleet
#   steal time       - how much CPU the hypervisor takes from you
#   jitter           - whether your vCPU gets descheduled under load
#   buffer setting   - should be the default (Nym asked to revert the 1000 workaround)
#   live test        - optional: wait for the next stress test and watch the node take it
#
# Read-only. Changes nothing.
#
#   ./node_stress_testing_probe.sh              # 60s sample
#   ./node_stress_testing_probe.sh 300          # 5min, catches bursty contention
#   ./node_stress_testing_probe.sh --wait-test  # also wait for the next stress test (up to 3h)
#
# Run it on a node that scores WELL too, and compare.

set -uo pipefail
SECS=60; WAIT_TEST=0
for a in "$@"; do
  case "$a" in
    --wait-test) WAIT_TEST=1 ;;
    *[!0-9]*|'') ;;
    *) SECS="$a" ;;
  esac
done
PORT="${NYM_HTTP_PORT:-8080}"   # nym-node's own HTTP API, for the live test
VERDICT=()

hr(){ printf '\n=============== %s ===============\n' "$1"; }
flag(){ VERDICT+=("$1"); echo "  >> $1"; }

# ---------------------------------------------------------------- identity --
hr "IDENTITY"
MODEL=$(lscpu | awk -F': *' '/Model name/{print $2; exit}')
MHZ=$(lscpu | awk -F': *' '/CPU max MHz/{printf "%.0f",$2; exit}')
[ -z "${MHZ:-}" ] && MHZ=$(lscpu | awk -F': *' '/CPU MHz/{printf "%.0f",$2; exit}')
[ -z "${MHZ:-}" ] && MHZ=$(awk -F': ' '/cpu MHz/{printf "%.0f",$2; exit}' /proc/cpuinfo)
echo "  host    : $(hostname)"
echo "  model   : ${MODEL:-unknown}"
echo "  clock   : ${MHZ:-unknown} MHz"
echo "  cores   : $(nproc)   (not a factor - one connection uses one core)"
echo "  RAM     : $(free -g | awk '/Mem:/{print $2}') GB   (not a factor)"
echo "  virt    : $(systemd-detect-virt 2>/dev/null || echo '?')"

# Fleet data: 80% of nodes at 2.0-2.2 GHz fail, 9% above 2.8 GHz fail.
# Nominal clock is a decent predictor but not conclusive: some fast cores
# report a low nominal MHz under virtualisation. The verdict is reconciled
# against the measured results in the SUMMARY.
if [ -n "${MHZ:-}" ] && [ "$MHZ" -gt 0 ] 2>/dev/null; then
  if   [ "$MHZ" -ge 2800 ]; then echo "  >> clock is comfortable (>=2.8 GHz band: 9% fail)"
  elif [ "$MHZ" -ge 2500 ]; then echo "  >> clock is adequate (2.5-2.8 band: 21% fail)"
  elif [ "$MHZ" -ge 2200 ]; then echo "  >> clock looks marginal (2.2-2.5 band: 41% fail) - see summary"
  else                           echo "  >> clock looks low (<2.2 band: 80% fail) - see summary"
  fi
fi

case "${MODEL:-}" in
  *QEMU*|*"Common KVM"*)
      flag "EMULATED CPU model - fleet median stress score 0.137" ;;
  *[0-9][0-9][0-9][0-9]*|*Ryzen*|*EPYC\ [0-9]*)
      echo "  >> real CPU model exposed - fleet median 0.991" ;;
  *)  flag "generic CPU model - hypervisor masking a shared tier, fleet median 0.853" ;;
esac

# --------------------------------------------------------------- contention --
hr "CPU CONTENTION  (${SECS}s sample)"
read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
sleep "$SECS"
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
tot=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u1+n1+s1+i1+w1+q1+sq1+st1) ))
awk -v s="$((st2-st1))" -v t="$tot" -v w="$((w2-w1))" 'BEGIN{
  printf "  steal   : %.2f%%\n", 100*s/t
  printf "  iowait  : %.2f%%\n", 100*w/t
}'
STEAL=$(awk -v s="$((st2-st1))" -v t="$tot" 'BEGIN{printf "%.2f",100*s/t}')
awk -v s="$STEAL" 'BEGIN{exit !(s >= 2)}' \
  && flag "noticeable CPU steal (${STEAL}%) - the host is oversubscribed" \
  || echo "  >> contention is low"

# ------------------------------------------------------------ single core --
hr "SINGLE-CORE SPEED  (what the stress test actually exercises)"
s=$(date +%s%N)
awk 'BEGIN{x=0; for(i=0;i<4000000;i++) x+=sqrt(i)}' >/dev/null
e=$(date +%s%N)
MS=$(( (e-s)/1000000 ))
echo "  4M sqrt loop : ${MS} ms"
[ "$MS" -gt 1500 ] && flag "single-core compute is slow (${MS} ms)" || echo "  >> single-core speed is fine"

# Reconcile the nominal clock against what the core actually did.
if [ -n "${MHZ:-}" ] && [ "$MHZ" -lt 2500 ] 2>/dev/null; then
  if [ "$MS" -le 400 ]; then
    echo "  >> nominal clock reads ${MHZ} MHz but this core is fast in practice -"
    echo "     treat the low clock reading as misleading, not as a problem"
  else
    flag "slow core (nominal ${MHZ} MHz, confirmed by measurement) - a buffer will not rescue this"
  fi
fi

hr "SCHEDULING JITTER"
if command -v python3 >/dev/null 2>&1; then
python3 - <<'PY'
import time
d=[]
for _ in range(200):
    t=time.perf_counter(); time.sleep(0.005)
    d.append((time.perf_counter()-t-0.005)*1000)
d.sort()
p95=d[int(len(d)*.95)]
print(f"  median {d[len(d)//2]:.2f} ms   p95 {p95:.2f} ms   max {d[-1]:.2f} ms")
print("  >> vCPU is being descheduled under load" if p95>5 else "  >> scheduling is clean")
PY
else
  echo "  python3 not available"
fi

# ----------------------------------------------------------- node config --
hr "NODE CONFIG"
CFG=$(ls -d /root/.nym/nym-nodes/*/config/config.toml 2>/dev/null | head -1)
if [ -n "$CFG" ]; then
  echo "  config  : $CFG"
  BUF=$(grep -oP '^\s*maximum_connection_buffer_size\s*=\s*\K[0-9]+' "$CFG" 2>/dev/null | head -1)
  if [ -n "$BUF" ] && [ "$BUF" -ne 192 ]; then
    echo "  maximum_connection_buffer_size = $BUF  (default 192)"
    flag "egress buffer set to $BUF - Nym asked to revert it: comment it out and restart nym-node"
  else
    echo "  >> egress buffer at the default (192), as Nym recommends"
  fi
else
  echo "  no nym-node config found"
fi

# ------------------------------------------------------------- live test --
# The tester pushes all its packets through ONE connection, far faster than any real peer
# (real peers carry well under 100 KB/s each; the 45k test runs at ~600 KB/s for ~30 s).
# Wait for a connection that moves >150 KB in a second and at least 5x the next busiest one,
# then watch nym-node's busiest thread and the drop counter for ~90 s.
if [ "$WAIT_TEST" -eq 1 ]; then
  hr "LIVE STRESS TEST  (waits up to 3h)"
  M="http://127.0.0.1:$PORT/api/v1/metrics/mixing"
  NPID=$(pgrep -o -x nym-node)
  if [ -z "$NPID" ] || ! curl -s -m 3 "$M" | grep -q received_since_startup; then
    echo "  nym-node not running or no metrics on $M (set NYM_HTTP_PORT)"
  else
    O=$(mktemp -d)
    cnt(){ curl -s -m 3 "$M" | grep -o "\"$1_since_startup\":[0-9]*" | cut -d: -f2; }
    conns(){ ss -Htin state established '( sport = :1789 )' 2>/dev/null | awk '
      /^[ \t]/ { if (match($0, /bytes_received:[0-9]+/)) print p, substr($0, RSTART + 15, RLENGTH - 15); next } { p = $4 }'; }
    echo "  waiting for the next stress test (roughly every 2 hours)..."
    conns > "$O/a"; END=$((SECONDS + 10800)); HIT=""
    while [ "$SECONDS" -lt "$END" ]; do
      sleep 1; conns > "$O/b"
      HIT=$(awk 'NR == FNR { p[$1] = $2; next }
                 { d = ($1 in p) ? $2 - p[$1] : $2; if (d > a) { b = a; a = d; h = $1 } else if (d > b) b = d }
                 END { if (a > 150000 && a > 5 * b) print h }' "$O/a" "$O/b")
      mv "$O/b" "$O/a"; [ -n "$HIT" ] && break
    done
    if [ -z "$HIT" ]; then
      echo "  no stress test seen in 3 hours - run with --wait-test again later"
    else
      T0=$(date -u +%T); R0=$(cnt received); D0=$(cnt dropped)
      top -H -b -d 1 -n 60 -p "$NPID" > "$O/top" 2>/dev/null &
      sleep 90
      RX=$(( $(cnt received) - R0 )); DR=$(( $(cnt dropped) - D0 ))
      # busiest thread per 1 s frame; test seconds = frames where it is above 10%
      read -r AVG HOT TOT < <(awk '/^top -/ { if (n) f[c++] = m; n = 1; m = 0; next }
          $1 ~ /^[0-9]+$/ && NF >= 12 { if ($9 + 0 > m) m = $9 + 0 }
          END { if (n) f[c++] = m; for (i = 0; i < c; i++) if (f[i] > 10) { s += f[i]; k++; if (f[i] >= 95) q++ }
                printf "%.0f %d %d\n", (k ? s / k : 0), q, k }' "$O/top")
      echo "  test at $T0 UTC from ${HIT%:*}"
      echo "  packets : received +$RX, dropped +$DR"
      echo "  busiest nym-node thread : avg ${AVG}%, ${HOT} of ${TOT} test seconds at 95%+"
      if [ "$DR" -gt 0 ] && [ "$TOT" -gt 0 ] && [ $(( HOT * 2 )) -ge "$TOT" ]; then
        flag "during the stress test one nym-node thread sat at ~100% and $DR packets were dropped - this core is too slow"
      elif [ "$DR" -gt 0 ]; then
        flag "$DR packets dropped during the stress test while no thread was pinned - not a CPU limit, look at the network"
      else
        echo "  >> the node took the stress test without drops"
      fi
    fi
    rm -rf "$O"
  fi
fi

# ---------------------------------------------------------------- score --
hr "CURRENT SCORE"
KEY=$(cat /root/.nym/nym-nodes/*/data/ed25519_identity.pub 2>/dev/null \
      | tr -d '"[:space:]' | grep -v 'BEGIN\|END' | head -1)
if [ -n "${KEY:-}" ] && command -v curl >/dev/null 2>&1; then
  echo "  identity : $KEY"
  echo "  look up your node_id, then:"
else
  echo "  identity key not found"
fi
echo "    curl -s https://validator.nymtech.net/api/v2/nym-nodes/annotation/<NODE_ID> | jq .annotation.detailed_performance"
echo "  (v1 does NOT show stress_testing_score - use v2)"

# --------------------------------------------------------------- summary --
hr "SUMMARY"
if [ ${#VERDICT[@]} -eq 0 ]; then
  echo "  Nothing flagged. If the score is still low, check was_reachable -"
  echo "  a false there is a firewall problem, not CPU."
else
  printf '  - %s\n' "${VERDICT[@]}"
fi
echo
echo "  Guide : https://github.com/serinko/nym-hacks/blob/master/debug/stress_testing/fixing-low-stress-score.md"
echo "  Report: https://github.com/serinko/nym-hacks/blob/master/debug/stress_testing/mixnode_stress_report.md"
echo
