# Struct#inspect / Data#inspect for a few member shapes. Usage: ruby [--yjit] inspect_bench.rb
S3 = Struct.new(:x, :y, :z)
D3 = Data.define(:x, :y, :z)
S8 = Struct.new(*%i[a b c d e f g h])
CASES = {
  "Struct 3 ints" => "si.inspect", "Struct 3 strings" => "ss.inspect", "Data 3 mixed" => "dm.inspect",
  "Struct 8 mixed" => "s8.inspect", "to_s" => "si.to_s", "Array 3 ints (reference)" => "ai.inspect",
}.freeze
ARGS = [S3.new(1, 2, 3), S3.new("a", "bb", "ccc"), D3.new(1, "two", :three), S8.new(1, "b", :c, nil, true, 2.5, [1], {k: 1}), [1, 2, 3]].freeze
ITERATIONS = 500_000
def define_case(name, expr)
  eval("def run_#{name}(si, ss, dm, s8, ai, n); k = 0; while k < n; #{expr}; k += 1; end; end", TOPLEVEL_BINDING)
end
CASES.each_with_index do |(label, expr), idx|
  define_case(idx, expr)
  200.times { send(:"run_#{idx}", *ARGS, 200) }
  ns = 3.times.map { t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond); send(:"run_#{idx}", *ARGS, ITERATIONS); (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(ITERATIONS) }.min
  puts format("%-28s %8.1f", label, ns)
end
