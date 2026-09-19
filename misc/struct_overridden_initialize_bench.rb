# Data / Struct classes whose initialize is overridden and calls super, against a plain class.
# Usage: ruby [--yjit|--zjit] overridden_initialize_bench.rb
class PlainKw
  def initialize(x:, y: 0)
    @x = x
    @y = y
  end
end

DataOverridden = Data.define(:x, :y) do
  def initialize(x:, y: 0) = super(x:, y:)
end

DataZsuper = Data.define(:x, :y) do
  def initialize(x:, y: 0) = super
end

StructKwOverridden = Struct.new(:x, :y, keyword_init: true) do
  def initialize(x:, y: 0) = super(x:, y:)
end

StructOverridden = Struct.new(:x, :y) do
  def initialize(x, y = 0) = super(x, y)
end

CASES = {
  "class: new(x: 1, y: 2)" => "PlainKw.new(x: 1, y: 2)",
  "Data, super(x:, y:): new(x: 1, y: 2)" => "DataOverridden.new(x: 1, y: 2)",
  "Data, super(x:, y:): new(1, 2)" => "DataOverridden.new(1, 2)",
  "Data, zsuper: new(x: 1, y: 2)" => "DataZsuper.new(x: 1, y: 2)",
  "Struct kw, super(x:, y:): new(x: 1, y: 2)" => "StructKwOverridden.new(x: 1, y: 2)",
  "Struct, super(x, y): new(1, 2)" => "StructOverridden.new(1, 2)",
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
  puts format("%-44s %7.1f", label, send(:"measure_#{idx}") - overhead)
end
