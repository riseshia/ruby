# If these C iteration methods were written in Ruby like Array#each / map / select already are,
# how fast would they be? The "ruby_" versions are plain Ruby monkeypatches (an upper bound sketch:
# no enumerator return, no c_trace), called on the same small Array.
# Usage: ruby [--yjit|--zjit] ruby_iteration_bench.rb
module Enumerable
  def ruby_each_with_index
    i = 0
    each { |x| yield x, i; i += 1 }
    self
  end

  def ruby_each_with_object(memo)
    each { |x| yield x, memo }
    memo
  end

  def ruby_flat_map
    result = []
    each { |x| y = yield(x); Array === y ? result.concat(y) : result << y }
    result
  end
end

class Array
  def ruby_reverse_each
    i = size - 1
    while i >= 0
      yield self[i]
      i -= 1
      i = size - 1 if i >= size
    end
    self
  end

  def ruby_each_index
    i = 0
    while i < size
      yield i
      i += 1
    end
    self
  end

  def ruby_find_index
    i = 0
    while i < size
      return i if yield(self[i])
      i += 1
    end
    nil
  end

  def ruby_reject
    result = []
    i = 0
    while i < size
      x = self[i]
      result << x unless yield(x)
      i += 1
    end
    result
  end

  def ruby_all?
    i = 0
    while i < size
      return false unless yield(self[i])
      i += 1
    end
    true
  end
end

CASES = {
  "each_with_index" => ["a.each_with_index { |x, i| x }", "a.ruby_each_with_index { |x, i| x }"],
  "each_with_object" => ["a.each_with_object([]) { |x, m| m << x }", "a.ruby_each_with_object([]) { |x, m| m << x }"],
  "flat_map" => ["a.flat_map { |x| [x, x] }", "a.ruby_flat_map { |x| [x, x] }"],
  "reverse_each" => ["a.reverse_each { |x| x }", "a.ruby_reverse_each { |x| x }"],
  "each_index" => ["a.each_index { |i| i }", "a.ruby_each_index { |i| i }"],
  "find_index { }" => ["a.find_index { |x| x == 3 }", "a.ruby_find_index { |x| x == 3 }"],
  "reject" => ["a.reject { |x| x == 2 }", "a.ruby_reject { |x| x == 2 }"],
  "all? { }" => ["a.all? { |x| x > 0 }", "a.ruby_all? { |x| x > 0 }"],
  "(already Ruby) each" => ["a.each { |x| x }", "a.each { |x| x }"],
}.freeze
ITERATIONS = 2_000_000
ROUNDS = 3

def define_case(name, expr)
  eval(<<~CODE, TOPLEVEL_BINDING, __FILE__, __LINE__ + 1)
    def run_#{name}(a, n)
      k = 0
      while k < n
        #{expr}
        k += 1
      end
    end

    def measure_#{name}(a)
      200.times { run_#{name}(a, 1_000) }
      ROUNDS.times.map {
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
        run_#{name}(a, ITERATIONS)
        (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0).fdiv(ITERATIONS)
      }.min
    end
  CODE
end

[[1, 2, 3], (1..20).to_a].each do |a|
  puts "-- Array of #{a.size}"
  puts format("%-22s %9s %9s", "method", "C ns", "Ruby ns")
  CASES.each_with_index do |(label, (c_expr, ruby_expr)), idx|
    define_case(:"c#{idx}_#{a.size}", c_expr)
    define_case(:"r#{idx}_#{a.size}", ruby_expr)
    puts format("%-22s %9.1f %9.1f", label, send(:"measure_c#{idx}_#{a.size}", a), send(:"measure_r#{idx}_#{a.size}", a))
  end
end
