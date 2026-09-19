# How much do Array#== / eql? / hash and Array-as-Hash-key cost, against doing the same by hand?
# They all run under a recursion guard even when the elements are plain values.
# Usage: ruby [--yjit] array_guard_bench.rb
CASES = {
  "[1, 2] == [1, 2]" => "a == b",
  "by hand: a[0] == b[0] && a[1] == b[1]" => "a[0] == b[0] && a[1] == b[1]",
  "[1, 2] == [1, 3]" => "a == c",
  "[1, 2].eql?([1, 2])" => "a.eql?(b)",
  "[1, 2].hash" => "a.hash",
  "hash[[1, 2]]" => "h[a]",
  "hash[1] (Integer key, for scale)" => "hi[1]",
  "hash[\"k\"] (String key, for scale)" => "hs[s]",
  "[1, \"k\", :sym] == same" => "t == u",
  "hash[[1, \"k\", :sym]]" => "ht[t]",
}.freeze

ITERATIONS = 3_000_000
ROUNDS = 5
PARAMS = %w[a b c h hi hs s t u ht].freeze

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(#{PARAMS.join(", ")}, n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}(*args)
      200.times { run_#{name}(*args, 1_000) }
      ROUNDS.times.map {
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(*args, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

t = [1, "k", :sym]
args = [[1, 2], [1, 2], [1, 3], {[1, 2] => 1}, {1 => 1}, {"k" => 1}, "k", t, [1, "k", :sym], {[1, "k", :sym] => 1}]
define_case(:empty, "a")
overhead = measure_empty(*args)
CASES.each_with_index do |(label, expr), idx|
  define_case(idx, expr)
  puts format("%-42s %7.1f", label, send(:"measure_#{idx}", *args) - overhead)
end
