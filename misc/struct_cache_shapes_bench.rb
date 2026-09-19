# Does the hidden-ivar inline cache hold up when classes do not share one shape?
# Usage: ruby cache_shapes_bench.rb
Direct = Struct.new(:x, :y)
class Inherited < Struct.new(:x, :y); end
WithClassIvar = Struct.new(:x, :y) { @registry = {} }
DirectData = Data.define(:x, :y)

CASES = {
  "Struct.new class" => "Direct.new(1, 2)",
  "class Foo < Struct.new" => "Inherited.new(1, 2)",
  "Struct.new class with its own @ivar" => "WithClassIvar.new(1, 2)",
  "alternating direct / inherited" => "Direct.new(1, 2); Inherited.new(1, 2)",
  "alternating Struct / Data" => "Direct.new(1, 2); DirectData.new(1, 2)",
}.freeze

ITERATIONS = 3_000_000
ROUNDS = 5

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}
      200.times { run_#{name}(1_000) }
      ROUNDS.times.map {
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

define_case(:empty, "nil")
overhead = measure_empty
CASES.each_with_index do |(label, expr), idx|
  define_case(idx, expr)
  puts format("%-38s %7.1f", label, send(:"measure_#{idx}") - overhead)
end
