# Array iteration methods, C (master) vs the JIT-only Ruby versions. Usage: ruby [--yjit|--zjit] array_iter_bench.rb
CASES = {
  "each_index (3)" => "a3.each_index { |i| i }",
  "each_index (20)" => "a20.each_index { |i| i }",
  "reject (3)" => "a3.reject { |x| x == 2 }",
  "reject (20)" => "a20.reject { |x| x > 10 }",
  "each (3), already Ruby" => "a3.each { |x| x }",
  "select (3), already Ruby" => "a3.select { |x| x == 2 }",
}.freeze
ITERATIONS = 2_000_000
ROUNDS = 3

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(a3, a20, n)
      k = 0
      while k < n
        #{expr}
        k += 1
      end
    end

    def measure_#{name}(a3, a20)
      200.times { run_#{name}(a3, a20, 1_000) }
      ROUNDS.times.map {
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(a3, a20, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

CASES.each_with_index do |(label, expr), idx|
  define_case(idx, expr)
  puts format("%-28s %8.1f", label, send(:"measure_#{idx}", [1, 2, 3], (1..20).to_a))
end
