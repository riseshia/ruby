#!/bin/bash
# Every benchmark the proposal quotes, on master (wt-base) and the branch (wt-vm), one after another
S=/tmp/claude-1000/-home-shia-repos-riseshia-ruby/5ff5b613-676a-4011-9004-e7c55ddf5b53/scratchpad
M=$S/wt-probe/misc
out=$S/bench_results; mkdir -p $out
modes=("" "--yjit" "--zjit --zjit-call-threshold=2 --zjit-num-profiles=1")
tags=(interp yjit zjit)
for i in 0 1 2; do
  for w in wt-base wt-vm; do
    BENCH_RUBY=$S/$w/ruby $S/$w/ruby ${modes[$i]} --disable-gems $M/initialize_matrix_bench.rb > $out/matrix.$w.${tags[$i]}.txt 2>&1
  done
done
for i in 0 1 2; do
  for w in wt-base wt-vm; do
    for op in with_lit eq_other hkey to_h inspect; do
      for k in class struct data; do
        [ $op = with_lit ] && [ $k = struct ] && continue
        best=$(for r in 1 2 3; do $S/$w/ruby ${modes[$i]} $M/struct_survey_cells_bench.rb $op $k 2>/dev/null | awk '{print $3}'; done | sort -n | head -1)
        echo "$op $k $best"
      done
    done > $out/ops.$w.${tags[$i]}.txt
  done
done
cd $S/ruby-bench
for i in 0 1 2; do
  for w in wt-base wt-vm; do
    for b in struct-new-no-escape data-new-no-escape; do
      best=$(WARMUP_ITRS=40 MIN_BENCH_ITRS=20 MIN_BENCH_TIME=0 OUT_CSV_PATH=/dev/null $S/$w/ruby ${modes[$i]} --disable-gems -I harness benchmarks/$b.rb 2>&1 | grep -oE "^itr #[0-9]+: +[0-9]+ms" | tail -20 | awk '{print $3}' | tr -d ms | sort -n | head -1)
      echo "$b $best"
    done > $out/rb.$w.${tags[$i]}.txt
  done
done
echo done
