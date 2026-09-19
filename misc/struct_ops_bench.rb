# Struct / Data operations other than construction that read the hidden class ivars.
# Usage: ruby [--yjit|--zjit] struct_ops_bench.rb
S = Struct.new(:x, :y, :z)
D = Data.define(:x, :y, :z)
BIG = Struct.new(*(1..12).map { :"m#{_1}" })

CASES = {
  "s[:y]" => "s[:y]",
  "s[1]" => "s[1]",
  "s[:y] = 1" => "s[:y] = 1",
  "big[:m12] (12 members)" => "big[:m12]",
  "s.to_h" => "s.to_h",
  "d.to_h" => "d.to_h",
  "s.members" => "s.members",
  "in {x:, y:} (Struct)" => "case s; in {x:, y:} then x; end",
  "in {x:, y:} (Data)" => "case d; in {x:, y:} then x; end",
  "d.with(y: 5)" => "d.with(y: 5)",
  "s.dig(:x)" => "s.dig(:x)",
  "s.values_at(0, 1)" => "s.values_at(0, 1)",
}.freeze

ITERATIONS = 3_000_000
ROUNDS = 5

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(s, d, big, n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}(s, d, big)
      200.times { run_#{name}(s, d, big, 1_000) }
      ROUNDS.times.map {
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(s, d, big, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

args = [S.new(1, 2, 3), D.new(1, 2, 3), BIG.new(*1..12)]
define_case(:empty, "s")
overhead = measure_empty(*args)
CASES.each_with_index do |(label, expr), idx|
  define_case(idx, expr)
  puts format("%-26s %7.1f", label, send(:"measure_#{idx}", *args) - overhead)
end
