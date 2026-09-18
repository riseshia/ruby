# The three operations backed by the ruby-bench headline tally: reader, writer, positional new.
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
  "reader" => {"plain" => "o.x", "Struct" => "s.x", "Data" => "d.x"},
  "writer" => {"plain" => "o.x = 1", "Struct" => "s.x = 1"},
  "new 2 members" => {"plain" => "Plain2.new(1, 2)", "Struct" => "Struct2.new(1, 2)", "Data" => "Data2.new(1, 2)"},
  "new 5 members" => {"plain" => "Plain5.new(1, 2, 3, 4, 5)", "Struct" => "Struct5.new(1, 2, 3, 4, 5)", "Data" => "Data5.new(1, 2, 3, 4, 5)"},
"new 2 keywords" => {"plain" => "PlainKw2.new(x: 1, y: 2)", "Struct" => "StructKw2.new(x: 1, y: 2)", "Data" => "Data2.new(x: 1, y: 2)"},
"new 5 keywords" => {"plain" => "PlainKw5.new(a: 1, b: 2, c: 3, d: 4, e: 5)", "Struct" => "StructKw5.new(a: 1, b: 2, c: 3, d: 4, e: 5)", "Data" => "Data5.new(a: 1, b: 2, c: 3, d: 4, e: 5)"},
}.freeze

ITERATIONS = 5_000_000
ROUNDS = 7

def define_runner(name, expr)
  eval(<<~RUBY, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def #{name}(o, s, d, n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end
  RUBY
end

def measure_ns(runner, args)
  # JITs count calls, not loop iterations: one long warm-up call would leave the loop interpreted.
  200.times { send(runner, *args, 1_000) }
  ROUNDS.times.map {
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    send(runner, *args, ITERATIONS)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(ITERATIONS)
  }.min
end

args = [Plain2.new(1, 2), Struct2.new(1, 2), Data2.new(1, 2)]
define_runner(:run_empty, "o")
overhead = measure_ns(:run_empty, args)

puts format("%-15s %8s %8s %8s", "op", "plain", "Struct", "Data")
CASES.each_with_index do |(label, exprs), idx|
  cells = %w[plain Struct Data].map { |kind|
    expr = exprs[kind] or next "-"
    runner = :"run_#{idx}_#{kind}"
    define_runner(runner, expr)
    format("%.1f", measure_ns(runner, args) - overhead)
  }
  puts format("%-15s %8s %8s %8s", label, *cells)
end
