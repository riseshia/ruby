#!/bin/bash
S=/tmp/claude-1000/-home-shia-repos-riseshia-ruby/5ff5b613-676a-4011-9004-e7c55ddf5b53/scratchpad; O=$S/bench2; mkdir -p $O
[ -d $S/ruby-bench ] || git clone -q --depth 1 https://github.com/ruby/ruby-bench.git $S/ruby-bench
sed 's/Point = Struct.new(:x, :y)/Point = Data.define(:x, :y)/' $S/ruby-bench/benchmarks/struct-new-no-escape.rb > $S/ruby-bench/benchmarks/data-new-no-escape.rb
modes=("" "--yjit" "--zjit --zjit-call-threshold=2 --zjit-num-profiles=1"); tags=(interp yjit zjit)
for i in 0 1 2; do for w in wt-base wt-core; do
  BENCH_RUBY=$S/$w/ruby $S/$w/ruby ${modes[$i]} --disable-gems $S/misc/initialize_matrix_bench.rb > $O/matrix.$w.${tags[$i]}.txt 2>&1
  for op in with_lit eq_other hkey to_h inspect; do for k in class struct data; do
    best=$(for r in 1 2 3; do $S/$w/ruby ${modes[$i]} $S/misc/struct_survey_cells_bench.rb $op $k 2>/dev/null | awk '{print $3}'; done | sort -n | head -1); echo "$op $k $best"
  done; done > $O/ops.$w.${tags[$i]}.txt
done; done
cd $S/ruby-bench
for i in 0 1 2; do for w in wt-base wt-core; do T=$S/$w; for b in struct-new-no-escape data-new-no-escape; do
  best=$(RUBYLIB="$T/lib:$T/.ext/common:$T/.ext/x86_64-linux:$T" WARMUP_ITRS=40 MIN_BENCH_ITRS=20 MIN_BENCH_TIME=0 OUT_CSV_PATH=/dev/null $T/ruby ${modes[$i]} --disable-gems -I harness benchmarks/$b.rb 2>&1 | grep -oE "^ *#[0-9]+: +[0-9]+ms" | tail -20 | awk '{print $2}' | tr -d ms | sort -n | head -1)
  echo "${tags[$i]} $w $b $best"; done; done; done > $O/ruby-bench.txt
echo done
