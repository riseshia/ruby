# Differential sweep: a core method implemented in C next to the same work written by hand in Ruby,
# on small everyday inputs. Where the C version loses badly there is hidden per-call overhead.
# Usage: ruby [--yjit] c_vs_ruby_sweep.rb   (prints ns per call and the C / Ruby ratio, worst first)
require "set"

class Money
  include Comparable
  attr_reader :cents
  def initialize(cents) = @cents = cents
  def <=>(other) = @cents <=> other.cents
end

PAIRS = {
  # label => [C expression, hand-written Ruby expression]
  "Array#== (2 ints)" => ["a2 == b2", "a2[0] == b2[0] && a2[1] == b2[1]"],
  "Array#<=> (2 ints)" => ["a2 <=> c2", "(a2[0] <=> c2[0]).nonzero? || a2[1] <=> c2[1]"],
  "Array#include? (3 ints, hit last)" => ["a3.include?(3)", "a3[0] == 3 || a3[1] == 3 || a3[2] == 3"],
  "Array#index (3 ints)" => ["a3.index(3)", "(a3[0] == 3 ? 0 : a3[1] == 3 ? 1 : a3[2] == 3 ? 2 : nil)"],
  "Array#max (2 ints)" => ["a2.max", "a2[0] > a2[1] ? a2[0] : a2[1]"],
  "[x, y].max literal" => ["[x, y].max", "x > y ? x : y"],
  "Array#minmax (3 ints)" => ["a3.minmax", "[a3[0], a3[2]]"],
  "Array#sum (3 ints)" => ["a3.sum", "a3[0] + a3[1] + a3[2]"],
  "Array#first" => ["a3.first", "a3[0]"],
  "Array#last" => ["a3.last", "a3[-1]"],
  "Array#dig (nested 2)" => ["nested.dig(0, 1)", "nested[0][1]"],
  "Array#fetch" => ["a3.fetch(1)", "a3[1]"],
  "Array#values_at (2)" => ["a3.values_at(0, 2)", "[a3[0], a3[2]]"],
  "Array#+ (2+2)" => ["a2 + b2", "[a2[0], a2[1], b2[0], b2[1]]"],
  "Array#compact (3, no nil)" => ["a3.compact", "[a3[0], a3[1], a3[2]]"],
  "Array#any? (no block)" => ["a3.any?", "!a3.empty?"],
  "Array#join (3 strings)" => ["strs.join(\",\")", "\"\#{strs[0]},\#{strs[1]},\#{strs[2]}\""],
  "Array#hash as Hash key" => ["by_ary[a2]", "by_int[a2[0] * 31 + a2[1]]"],
  "Array(x) on an Array" => ["Array(a3)", "a3"],
  "Hash#== (2 pairs)" => ["h2 == g2", "h2.size == g2.size && h2[:a] == g2[:a] && h2[:b] == g2[:b]"],
  "Hash#fetch (hit)" => ["h2.fetch(:a)", "h2[:a]"],
  "Hash#fetch with default" => ["h2.fetch(:z, 0)", "h2.key?(:z) ? h2[:z] : 0"],
  "Hash#dig (nested 2)" => ["nested_h.dig(:a, :b)", "nested_h[:a][:b]"],
  "Hash#merge (2+1)" => ["h2.merge(h1)", "{a: h2[:a], b: h2[:b], c: h1[:c]}"],
  "Hash#slice (1 of 2)" => ["h2.slice(:a)", "{a: h2[:a]}"],
  "Hash#values_at" => ["h2.values_at(:a, :b)", "[h2[:a], h2[:b]]"],
  "Hash#to_a (2 pairs)" => ["h2.to_a", "[[:a, h2[:a]], [:b, h2[:b]]]"],
  "Comparable#==" => ["m1 == m2", "m1.cents == m2.cents"],
  "Comparable#<" => ["m1 < m3", "m1.cents < m3.cents"],
  "Comparable#between?" => ["m1.between?(m0, m3)", "m0.cents <= m1.cents && m1.cents <= m3.cents"],
  "Comparable#clamp" => ["m1.clamp(m0, m3)", "m1.cents < m0.cents ? m0 : m1.cents > m3.cents ? m3 : m1"],
  "Integer#clamp" => ["x.clamp(0, 10)", "x < 0 ? 0 : x > 10 ? 10 : x"],
  "Integer#between?" => ["x.between?(0, 10)", "0 <= x && x <= 10"],
  "Integer#zero? / positive?" => ["x.positive?", "x > 0"],
  "Integer#pow (small)" => ["x.pow(2)", "x * x"],
  "Integer#divmod" => ["y.divmod(3)", "[y / 3, y % 3]"],
  "Range#== (ints)" => ["r1 == r2", "r1.begin == r2.begin && r1.end == r2.end && r1.exclude_end? == r2.exclude_end?"],
  "Range#include? / ===" => ["r1.include?(x)", "r1.begin <= x && x <= r1.end"],
  "Range#cover?" => ["r1.cover?(x)", "r1.begin <= x && x <= r1.end"],
  "Range#to_a (3)" => ["(1..3).to_a", "[1, 2, 3]"],
  "Set#include?" => ["set.include?(2)", "by_int.key?(2)"],
  "Set#== (2)" => ["set == set2", "set.size == set2.size && set2.include?(1) && set2.include?(2)"],
  "String#== (short)" => ["s1 == s2", "s1.eql?(s2)"],
  "String#start_with?" => ["s1.start_with?(\"he\")", "s1[0, 2] == \"he\""],
  "Symbol#to_proc call (map)" => ["a3.map(&:to_s)", "[a3[0].to_s, a3[1].to_s, a3[2].to_s]"],
  "Kernel#Integer(str)" => ["Integer(num)", "num.to_i"],
  "Kernel#Integer(str, exception: false)" => ["Integer(num, exception: false)", "num.to_i"],
  "Kernel#Float(str)" => ["Float(flt)", "flt.to_f"],
  "Kernel#format(\"%d\")" => ["format(\"%d\", x)", "x.to_s"],
  "Object#then" => ["x.then { _1 + 1 }", "x + 1"],
  "Object#tap" => ["x.tap { _1 }", "x"],
  "Object#is_a?" => ["x.is_a?(Integer)", "Integer === x"],
  "Object#respond_to?" => ["x.respond_to?(:succ)", "true"],
  "Object#dup (2 ivars)" => ["m1.dup", "Money.new(m1.cents)"],
  "Object#instance_variable_get" => ["m1.instance_variable_get(:@cents)", "m1.cents"],
  "Object#send" => ["m1.send(:cents)", "m1.cents"],
  "Object#public_send" => ["m1.public_send(:cents)", "m1.cents"],
  "Object#hash (default)" => ["m1.hash", "m1.cents"],
  "Object#== (default)" => ["obj == obj2", "obj.equal?(obj2)"],
  "Object#!= (default ==)" => ["obj != obj2", "!obj.equal?(obj2)"],
  "Time#<=> / Comparable" => ["t1 < t2", "t1.to_f < t2.to_f"],
}.freeze

PARAMS = %w[a2 b2 c2 a3 nested strs by_ary by_int h1 h2 g2 nested_h m0 m1 m2 m3 x y r1 r2 set set2 s1 s2 num flt obj obj2 t1 t2].freeze
ARGS = [[1, 2], [1, 2], [1, 3], [1, 2, 3], [[1, 2], [3]], %w[a b c], {[1, 2] => 1}, {33 => 1, 2 => 1}, {c: 3}, {a: 1, b: 2}, {a: 1, b: 2},
        {a: {b: 1}}, Money.new(0), Money.new(5), Money.new(5), Money.new(9), 5, 17, (1..10), (1..10), Set[1, 2], Set[1, 2],
        "hello", "hello".dup, "42", "4.2", Object.new, Object.new, Time.at(1), Time.at(2)].freeze
ITERATIONS = 2_000_000
ROUNDS = 3

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

define_case(:empty, "x")
overhead = measure_empty
rows = PAIRS.each_with_index.map { |(label, (c_expr, ruby_expr)), idx|
  define_case(:"c#{idx}", c_expr)
  define_case(:"r#{idx}", ruby_expr)
  c_ns = [send(:"measure_c#{idx}") - overhead, 0.1].max
  ruby_ns = [send(:"measure_r#{idx}") - overhead, 0.1].max
  [label, c_ns, ruby_ns, c_ns / ruby_ns, c_ns - ruby_ns]
}
puts format("%-40s %9s %9s %8s %9s", "method", "C ns", "Ruby ns", "ratio", "extra ns")
rows.sort_by { -_1[4] }.each { |label, c_ns, ruby_ns, ratio, extra| puts format("%-40s %9.1f %9.1f %7.1fx %9.1f", label, c_ns, ruby_ns, ratio, extra) }
