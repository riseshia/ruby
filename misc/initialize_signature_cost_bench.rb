# How much does a generic initialize signature cost compared to a fixed one?
# A single `Struct#initialize` written in Ruby would have to accept any member count.
# Usage: ruby [--yjit|--zjit] signature_cost_bench.rb

class Fixed
  def initialize(a = nil, b = nil) = (@a = a; @b = b)
end

class OptionalAndRest
  def initialize(a = nil, b = nil, *rest) = (@a = a; @b = b)
end

class RestOnly
  def initialize(*args) = (@a = args[0]; @b = args[1])
end

class OptionalRestKwrest
  def initialize(a = nil, b = nil, *rest, **kw) = (@a = a; @b = b)
end

class OptionalAndKwrest
  def initialize(a = nil, b = nil, **kw) = (@a = a; @b = b)
end

class OptionalEight
  def initialize(a = nil, b = nil, c = nil, d = nil, e = nil, f = nil, g = nil, h = nil) = (@a = a; @b = b)
end

class Forwarding
  def initialize(...) = assign(...)
  def assign(a = nil, b = nil) = (@a = a; @b = b)
end

CASES = {
  "(a = nil, b = nil)" => "Fixed.new(1, 2)",
  "(a = nil, b = nil, *rest)" => "OptionalAndRest.new(1, 2)",
  "(*args)" => "RestOnly.new(1, 2)",
  "(a = nil, b = nil, *rest, **kw)" => "OptionalRestKwrest.new(1, 2)",
  "(a = nil, b = nil, **kw)" => "OptionalAndKwrest.new(1, 2)",
  "(a = nil, b = nil, **kw) called with keywords" => "OptionalAndKwrest.new(a: 1, b: 2)",
  "(a = nil, ... h = nil) eight optionals" => "OptionalEight.new(1, 2)",
  "(...) forwarding to fixed" => "Forwarding.new(1, 2)",
}.freeze

ITERATIONS = 5_000_000
ROUNDS = 7

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
  puts format("%-46s %7.1f", label, send(:"measure_#{idx}") - overhead)
end
