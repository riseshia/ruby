# dup / clone of everyday objects, next to another way of getting the same copy.
# Usage: ruby [--yjit] dup_bench.rb
class Point
  attr_reader :x, :y
  def initialize(x, y) = (@x = x; @y = y)
end

CASES = {
  "obj.dup (2 ivars)" => "obj.dup",
  "obj.clone" => "obj.clone",
  "Point.new(obj.x, obj.y)" => "Point.new(obj.x, obj.y)",
  "[1, 2, 3].dup" => "ary.dup",
  "ary[0..] / [*ary]" => "[*ary]",
  "{a: 1}.dup" => "hash.dup",
  "{**hash}" => "{**hash}",
  "\"str\".dup" => "str.dup",
  "+\"\" << str equivalent: String.new(str)" => "String.new(str)",
  "Object.new.dup (no ivars)" => "bare.dup",
}.freeze
PARAMS = %w[obj ary hash str bare].freeze
ARGS = [Point.new(1, 2), [1, 2, 3], {a: 1}, "str", Object.new].freeze
ITERATIONS = 3_000_000
ROUNDS = 5

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(#{PARAMS.join(", ")}, n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}
      200.times { run_#{name}(*ARGS, 1_000) }
      ROUNDS.times.map {
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(*ARGS, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

define_case(:empty, "obj")
overhead = measure_empty
CASES.each_with_index do |(label, expr), idx|
  define_case(idx, expr)
  puts format("%-44s %7.1f", label, send(:"measure_#{idx}") - overhead)
end
