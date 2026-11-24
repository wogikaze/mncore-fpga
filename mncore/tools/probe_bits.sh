#!/bin/bash
# assemble3 を差分オラクルとして、PE 命令語 (426bit) のどのビットが変わるかを見る最小プローブ。
# WSL (Ubuntu) で実行:  wsl -d Ubuntu -- bash /mnt/c/wgkz/nano20k/mncore/tools/probe_bits.sh
# 前提: ~/wgkz/mncore/judge (setup_judge.sh で展開済み)
A=${ASSEMBLE3:-~/wgkz/mncore/judge/judge-py/mncore2_emuenv/assemble3}
base=""
for src in \
  'lpassa $lm0v $ln0v' \
  'lpassa $lm8v $ln0v' \
  'lpassa $lm16v $ln0v' \
  'lpassa $lm0v $ln8v' \
  'ipassa $lm0v $ln0v' \
  'iinc $lm0v $ln0v' \
  'iadd $lm0v $lr0v $ln0v' \
  'nop' \
  'lpassa $lm0v $ln0v;fvadd $lr0v $ls0v $nowrite'; do
  w=$(echo "$src" | $A --instruction-mode flat 2>&1 | grep '^j' | head -1 | cut -c3-)
  [ -z "$base" ] && base=$w
  diff=$(python3 -c "import sys;a,b=sys.argv[1],sys.argv[2];print(','.join(str(i) for i in range(len(a)) if a[i]!=b[i]))" "$base" "$w")
  ones=$(python3 -c "import sys;print([i for i,c in enumerate(sys.argv[1]) if c=='1'])" "$w")
  printf '%-45s diff_vs_first=[%s]\n   ones=%s\n' "$src" "$diff" "$ones"
done
