# Other core methods that run under a recursion guard, each next to the same work done by hand.
# Usage: ruby [--yjit] guard_sites_bench.rb
class Version
  include Comparable
  attr_reader :n
  def initialize(n) = @n = n
  def <=>(other) = @n <=> other.n
end

class VersionWithEq < Version
  def ==(other) = other.is_a?(Version) && @n == other.n
end

CASES = {
  "[1, 2] <=> [1, 3]" => "a <=> c",
  "by hand: (a[0] <=> c[0]).nonzero? || a[1] <=> c[1]" => "(a[0] <=> c[0]).nonzero? || a[1] <=> c[1]",
  "pairs.sort (1000 [Integer, Integer])" => "pairs.sort",
  "pairs.sort_by { [_1[0], _1[1]] }" => "pairs.sort_by { |x| [x[0], x[1]] }",
  "pairs.sort { by hand }" => "pairs.sort { |x, y| (x[0] <=> y[0]).nonzero? || x[1] <=> y[1] }",
  "(1..2) == (1..2)" => "r1 == r2",
  "(1..2).eql?(1..2)" => "r1.eql?(r2)",
  "hash[(1..2)]" => "hr[r1]",
  "{a: 1, b: 2} == {a: 1, b: 2}" => "h1 == h2",
  "{a: 1, b: 2} == {a: 1, b: 3}" => "h1 == h3",
  "Comparable#== (v1 == v2)" => "v1 == v2",
  "hand-written == on the same class" => "w1 == w2",
  "Set[1, 2] == Set[1, 2]" => "s1 == s2",
}.freeze
SLOW = ["pairs.sort", "pairs.sort_by { |x| [x[0], x[1]] }", "pairs.sort { |x, y| (x[0] <=> y[0]).nonzero? || x[1] <=> y[1] }"].freeze

ROUNDS = 5
PARAMS = %w[a c pairs r1 r2 hr h1 h2 h3 v1 v2 w1 w2 s1 s2].freeze

def define_case(name, expr, iterations)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(#{PARAMS.join(", ")}, n)
      i = 0
      while i < n
        #{expr}
        i += 1
      end
    end

    def measure_#{name}(*args)
      200.times { run_#{name}(*args, #{[iterations / 3000, 1].max}) }
      ROUNDS.times.map {
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(*args, #{iterations})
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0).fdiv(#{iterations})
      }.min
    end
  CODE
end

random = Random.new(42)
pairs = Array.new(1000) { [random.rand(50), random.rand(1000)] }
require "set"
args = [[1, 2], [1, 3], pairs, (1..2), (1..2), {(1..2) => 1}, {a: 1, b: 2}, {a: 1, b: 2}, {a: 1, b: 3},
        Version.new(1), Version.new(1), VersionWithEq.new(1), VersionWithEq.new(1), Set[1, 2], Set[1, 2]]
define_case(:empty, "a", 3_000_000)
overhead = measure_empty(*args)
CASES.each_with_index do |(label, expr), idx|
  slow = SLOW.include?(expr)
  define_case(idx, expr, slow ? 300 : 3_000_000)
  ns = send(:"measure_#{idx}", *args) - (slow ? 0 : overhead)
  puts slow ? format("%-52s %9.1f us", label, ns / 1000) : format("%-52s %9.1f ns", label, ns)
end
