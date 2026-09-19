# The three operations backed by the ruby-bench headline tally: reader, writer, positional new.
# The "class" column is a hand-written class doing the same job, the speed Struct / Data are compared to.
# Usage: ruby [--yjit|--zjit] core3_bench.rb

class Plain2
  attr_accessor :x, :y

  def initialize(x, y)
    @x = x
    @y = y
  end
end

class Plain5
  attr_accessor :a, :b, :c, :d, :e

  def initialize(a, b, c, d, e)
    @a = a
    @b = b
    @c = c
    @d = d
    @e = e
  end
end

class PlainKw2
  def initialize(x:, y:)
    @x = x
    @y = y
  end
end

class PlainKw5
  def initialize(a:, b:, c:, d:, e:)
    @a = a
    @b = b
    @c = c
    @d = d
    @e = e
  end
end

StructKw2 = Struct.new(:x, :y, keyword_init: true)
StructKw5 = Struct.new(:a, :b, :c, :d, :e, keyword_init: true)
Struct2 = Struct.new(:x, :y)
Struct5 = Struct.new(:a, :b, :c, :d, :e)
Data2 = Data.define(:x, :y)
Data5 = Data.define(:a, :b, :c, :d, :e)

CASES = {
  "reader" => {"class" => "o.x", "Struct" => "s.x", "Data" => "d.x"},
  "writer" => {"class" => "o.x = 1", "Struct" => "s.x = 1"},
  "new 2 members" => {"class" => "Plain2.new(1, 2)", "Struct" => "Struct2.new(1, 2)", "Data" => "Data2.new(1, 2)"},
  "new 5 members" => {"class" => "Plain5.new(1, 2, 3, 4, 5)", "Struct" => "Struct5.new(1, 2, 3, 4, 5)", "Data" => "Data5.new(1, 2, 3, 4, 5)"},
"new 2 keywords" => {"class" => "PlainKw2.new(x: 1, y: 2)", "Struct" => "StructKw2.new(x: 1, y: 2)", "Data" => "Data2.new(x: 1, y: 2)"},
"new 5 keywords" => {"class" => "PlainKw5.new(a: 1, b: 2, c: 3, d: 4, e: 5)", "Struct" => "StructKw5.new(a: 1, b: 2, c: 3, d: 4, e: 5)", "Data" => "Data5.new(a: 1, b: 2, c: 3, d: 4, e: 5)"},
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

args = [Plain2.new(1, 2), Struct2.new(1, 2), Data2.new(1, 2)]
define_case(:empty, "o", %w[o s d])
overhead = measure_empty(*args)

puts format("%-15s %8s %8s %8s", "op", "class", "Struct", "Data")
CASES.each_with_index do |(label, exprs), idx|
  cells = %w[class Struct Data].map { |kind|
    expr = exprs[kind] or next "-"
    define_case(:"#{idx}_#{kind}", expr, %w[o s d])
    format("%.1f", send(:"measure_#{idx}_#{kind}", *args) - overhead)
  }
  puts format("%-15s %8s %8s %8s", label, *cells)
end
