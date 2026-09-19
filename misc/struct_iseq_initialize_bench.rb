# What if Struct#initialize were a per-class Ruby (ISEQ) method instead of the shared C function?
# Storage stays T_STRUCT; only initialize changes, written with the member setters.
# Usage: ruby [--yjit|--zjit] iseq_init_bench.rb CASE_INDEX

class Class2
  def initialize(x, y)
    @x = x
    @y = y
  end
end

class ClassKw2
  def initialize(x:, y:)
    @x = x
    @y = y
  end
end

StructC2 = Struct.new(:x, :y)
StructCKw2 = Struct.new(:x, :y, keyword_init: true)

StructIseq2 = Struct.new(:x, :y) do
  def initialize(x = nil, y = nil)
    self.x = x
    self.y = y
  end
end

StructIseqKw2 = Struct.new(:x, :y, keyword_init: true) do
  def initialize(x: nil, y: nil)
    self.x = x
    self.y = y
  end
end

CASES = {
  "positional: class" => "Class2.new(1, 2)",
  "positional: Struct, C initialize" => "StructC2.new(1, 2)",
  "positional: Struct, ISEQ initialize" => "StructIseq2.new(1, 2)",
  "keywords: class" => "ClassKw2.new(x: 1, y: 2)",
  "keywords: Struct, C initialize" => "StructCKw2.new(x: 1, y: 2)",
  "keywords: Struct, ISEQ initialize" => "StructIseqKw2.new(x: 1, y: 2)",
}.freeze

ITERATIONS = 5_000_000
ROUNDS = 7

# Each case gets its own runner and its own measuring method that calls the runner directly.
# Calling runners through one shared `send` site leaves YJIT specialised on the first runner,
# and later ones are then measured on a slow path.
def define_case(name, expr, params)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(#{[*params, "n"].join(", ")})
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}(#{params.join(", ")})
      # JITs count calls, not loop iterations: one long warm-up call would leave the loop interpreted.
      200.times { run_#{name}(#{[*params, "1_000"].join(", ")}) }
      ROUNDS.times.map {
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(#{[*params, "ITERATIONS"].join(", ")})
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

abort "usage: ruby iseq_init_bench.rb CASE_INDEX (0..#{CASES.size - 1})" if ARGV.empty?

label, expr = CASES.to_a.fetch(Integer(ARGV[0]))
define_case(:empty, "nil", [])
define_case(:case, expr, [])
overhead = measure_empty
puts format("%-38s %7.1f", label, measure_case - overhead)
