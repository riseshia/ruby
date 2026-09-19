# == / eql? / hash / Hash key lookup for Struct and Data against a hand-written class.
# Usage: ruby [--yjit] equality_bench.rb
S = Struct.new(:x, :y)
D = Data.define(:x, :y)

class C
  attr_reader :x, :y

  def initialize(x, y) = (@x = x; @y = y)
  def ==(other) = other.class == self.class && @x == other.x && @y == other.y
  def eql?(other) = other.class == self.class && @x.eql?(other.x) && @y.eql?(other.y)
  def hash = [self.class, @x, @y].hash
end

CASES = {
  "== (equal)" => "a == b",
  "== (different)" => "a == c",
  "eql? (equal)" => "a.eql?(b)",
  "hash" => "a.hash",
  "Hash#[] with it as key" => "h[a]",
}.freeze
KLASSES = {"class" => C, "Struct" => S, "Data" => D}.freeze

ITERATIONS = 3_000_000
ROUNDS = 5

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(a, b, c, h, n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}(a, b, c, h)
      200.times { run_#{name}(a, b, c, h, 1_000) }
      ROUNDS.times.map {
        t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(a, b, c, h, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

define_case(:empty, "a")
puts format("%-24s %8s %8s %8s", "op", *KLASSES.keys)
CASES.each_with_index do |(label, expr), idx|
  cells = KLASSES.map { |kname, klass|
    args = [klass.new(1, "k"), klass.new(1, "k"), klass.new(1, "other")]
    args << {args[1] => 1}
    define_case(:"#{idx}_#{kname}", expr)
    format("%.1f", send(:"measure_#{idx}_#{kname}", *args) - measure_empty(*args))
  }
  puts format("%-24s %8s %8s %8s", label, *cells)
end
