# Ways of reaching a member other than a plain `o.x`, for a hand-written class, a Struct and a Data.
# One process per cell (see struct_new_matrix_bench.rb). ns per operation.
class C; attr_accessor :x, :y; def initialize(x, y) = (@x = x; @y = y); end
class CSuper < C; def x = super; end
class CWSuper < C; def x=(v); super; end; end
SWSuper = Class.new(Struct.new(:x, :y)) { def x=(v); super; end }
S = Struct.new(:x, :y); SSuper = Class.new(S) { def x = super }
D = Data.define(:x, :y); DSuper = Class.new(D) { def x = super }
LIST = {"C" => C, "S" => S, "D" => D}.transform_values { |k| Array.new(100) { |i| k.new(i, i) }.freeze }
CASES = {
  "o.x"                      => ["C.new(1, 2)", "S.new(1, 2)", "D.new(1, 2)", "o.x"],
  "reader overridden, super" => ["CSuper.new(1, 2)", "SSuper.new(1, 2)", "DSuper.new(1, 2)", "o.x"],
  "writer overridden, super" => ["CWSuper.new(1, 2)", "SWSuper.new(1, 2)", nil, "o.x = 1"],
  "o.send(:x)"               => ["C.new(1, 2)", "S.new(1, 2)", "D.new(1, 2)", "o.send(:x)"],
  "o.public_send(:x)"        => ["C.new(1, 2)", "S.new(1, 2)", "D.new(1, 2)", "o.public_send(:x)"],
  "list.map(&:x) /100"       => ["LIST['C']", "LIST['S']", "LIST['D']", "o.map(&:x)"],
  "list.sum(&:x) /100"       => ["LIST['C']", "LIST['S']", "LIST['D']", "o.sum(&:x)"],
  "list.sort_by(&:x) /100"   => ["LIST['C']", "LIST['S']", "LIST['D']", "o.sort_by(&:x)"],
  "list.map { _1.x } /100"   => ["LIST['C']", "LIST['S']", "LIST['D']", "o.map { _1.x }"],
  "o.x = 1 via send"         => ["C.new(1, 2)", "S.new(1, 2)", nil, "o.send(:x=, 1)"],
  "m = o.method(:x); m.call" => ["C.new(1, 2).method(:x)", "S.new(1, 2).method(:x)", "D.new(1, 2).method(:x)", "o.call"],
  "o.respond_to?(:x)"        => ["C.new(1, 2)", "S.new(1, 2)", "D.new(1, 2)", "o.respond_to?(:x)"],
}
if ARGV[0] == "--cell"
  setup = CASES.values[ARGV[1].to_i]
  OBJ = eval(setup[ARGV[2].to_i])
  div = CASES.keys[ARGV[1].to_i].end_with?("/100") ? 100 : 1
  n = div == 100 ? 20_000 : 2_000_000
  eval <<~CELL
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    def run(o, n) = (i = 0; while i < n; #{setup[3]}; i += 1; end)
    def empty(o, n) = (i = 0; while i < n; i += 1; end)
    w = 0; while w < 200; run(OBJ, 10); empty(OBJ, 10); w += 1; end
    best = nil; base = nil; r = 0
    while r < 5
      t = now; empty(OBJ, #{n}); e = now - t; base = e if base.nil? || e < base
      t = now; run(OBJ, #{n}); e = now - t; best = e if best.nil? || e < best
      r += 1
    end
    puts (best - base).fdiv(#{n} * #{div})
  CELL
  exit
end
jit = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? then ["--yjit"] elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit"] else [] end
ruby = ENV.fetch("BENCH_RUBY")
puts format("%-28s %7s %7s %7s", "", "class", "Struct", "Data")
CASES.each_with_index do |(label, setup), row|
  next unless ARGV.empty? || ARGV.any? { label.include?(_1) }
  cells = (0..2).map { |col| setup[col] && IO.popen([ruby, "--disable-gems", *jit, __FILE__, "--cell", row.to_s, col.to_s], err: File::NULL, &:read).to_f }
  puts format("%-28s %s", label, cells.map { _1 ? format("%7.1f", _1) : format("%7s", "-") }.join(" "))
end
