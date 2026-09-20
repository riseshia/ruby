# Second differential sweep: C methods that are called a lot in the ruby-bench headline
# benchmarks, next to the same work written by hand. Usage: ruby [--yjit] c_vs_ruby_sweep2.rb
class Widget
  attr_reader :size
  def initialize(size) = @size = size
  def call_block = block_given?
  def call_defined = defined?(yield) ? true : false
end
SIZE_METHOD = Widget.instance_method(:size)

PAIRS = {
  "String.new" => ["String.new", "+\"\""],
  "String.new(capacity: 64)" => ["String.new(capacity: 64)", "+\"\""],
  "String.new(\"abc\")" => ["String.new(s)", "+s"],
  "String#dup" => ["s.dup", "+s"],
  "String#-@ (already frozen)" => ["-fs", "fs"],
  "UnboundMethod#bind_call" => ["SIZE_METHOD.bind_call(w)", "w.size"],
  "Kernel#public_send" => ["w.public_send(:size)", "w.size"],
  "Kernel#block_given?" => ["w.call_block", "w.call_defined"],
  "Thread.current" => ["Thread.current", "th"],
  "Thread.current[:key]" => ["Thread.current[:key]", "local[:key]"],
  "Kernel#instance_of?" => ["x.instance_of?(Integer)", "x.class == Integer"],
  "Kernel#kind_of? (hit)" => ["x.kind_of?(Integer)", "Integer === x"],
  "Kernel#kind_of? (module, miss)" => ["w.kind_of?(Comparable)", "Comparable === w"],
  "Kernel#instance_variable_set" => ["w.instance_variable_set(:@size, 1)", "w.size"],
  "Kernel#object_id" => ["w.object_id", "w.size"],
  "Kernel#__method__" => ["__method__", ":run"],
  "Class#allocate" => ["Widget.allocate", "Widget.new(1)"],
  "Array#each_with_index (3)" => ["a3.each_with_index { |e, i| e }", "i = 0; a3.each { |e| i += 1 }"],
  "Array#each_slice(2) (4)" => ["a4.each_slice(2) { |e| e }", "a4[0, 2]; a4[2, 2]"],
  "Array#each_with_object (3)" => ["a3.each_with_object([]) { |e, acc| acc << e }", "acc = []; a3.each { |e| acc << e }; acc"],
  "Array#flat_map (3)" => ["a3.flat_map { |e| [e, e] }", "acc = []; a3.each { |e| acc << e << e }; acc"],
  "Array#concat" => ["[].concat(a3)", "[*a3]"],
  "Array#push (1)" => ["[].push(1)", "[] << 1"],
  "Array#| (3|3)" => ["a3 | b3", "a3 + [4]"],
  "Array#clear (empty)" => ["e.clear", "e.empty?"],
  "Array#reverse_each (3)" => ["a3.reverse_each { |e| e }", "a3.each { |e| e }"],
  "Array#find_index (block)" => ["a3.find_index { |e| e == 3 }", "a3.index(3)"],
  "Array#bsearch_index" => ["sorted.bsearch_index { |e| e >= 50 }", "sorted.index(50)"],
  "Hash#delete (miss)" => ["h2.delete(:zz)", "h2[:zz]"],
  "Hash#keys (2)" => ["h2.keys", "[:a, :b]"],
  "Hash#each (2)" => ["h2.each { |k, v| v }", "h2[:a]; h2[:b]"],
  "Hash#freeze (already frozen)" => ["fh.freeze", "fh"],
  "Symbol#end_with?" => ["sym.end_with?(\"=\")", "sym == :name="],
  "String#to_sym (existing)" => ["s.to_sym", "sym"],
  "String#casecmp" => ["s.casecmp(t)", "s == t"],
  "String#include?" => ["s.include?(\"b\")", "s == t"],
  "Integer#to_s" => ["x.to_s", "s"],
  "Module#=== (class)" => ["Widget === w", "w.class == Widget"],
  "Module#== " => ["Widget == Widget", "Widget.equal?(Widget)"],
  "BasicObject#equal?" => ["w.equal?(w)", "true"],
  "Class#superclass" => ["Widget.superclass", "Object"],
  "Module#name" => ["Widget.name", "s"],
}.freeze

PARAMS = %w[s fs w th local x a3 a4 b3 e sorted h2 fh sym t].freeze
ARGS = ["abc", "abc".freeze, Widget.new(3), Thread.current, {key: 1}, 5, [1, 2, 3], [1, 2, 3, 4], [3, 4, 5], [], (0..99).to_a,
        {a: 1, b: 2}, {a: 1}.freeze, :name=, "abd"].freeze
ITERATIONS = 2_000_000
ROUNDS = 3

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(#{PARAMS.join(", ")}, n)
      i = 0
      while i < n
        #{expr.gsub(/\bi\b/, "k")}
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
  [label, c_ns, ruby_ns, c_ns - ruby_ns]
}
puts format("%-34s %9s %9s %9s", "method", "C ns", "Ruby ns", "extra ns")
rows.sort_by { -_1[3] }.each { |label, c_ns, ruby_ns, extra| puts format("%-34s %9.1f %9.1f %9.1f", label, c_ns, ruby_ns, extra) }
