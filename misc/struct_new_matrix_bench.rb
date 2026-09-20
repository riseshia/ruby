# ns per construction for a hand-written class, a Struct and a Data, with 2 and 5
# members, positional and keyword.
#
# Every cell runs in its own process. Two things make cells in one process depend on
# the order they run in: a JIT specializes shared call sites (and only counts calls
# coming from the interpreter), and an earlier cell leaves a bigger heap, which makes
# later allocation loops miss the CPU cache more (a plain class goes from 15ns to 32ns).
# Inside a cell everything is straight-line top-level code: no send, no blocks.
N = 2_000_000
ROUNDS = 7

class C2; def initialize(x, y) = (@x = x; @y = y); end
class C5; def initialize(a, b, c, d, e) = (@a = a; @b = b; @c = c; @d = d; @e = e); end
class K2; def initialize(x:, y:) = (@x = x; @y = y); end
class K5; def initialize(a:, b:, c:, d:, e:) = (@a = a; @b = b; @c = c; @d = d; @e = e); end
S2 = Struct.new(:x, :y); S5 = Struct.new(:a, :b, :c, :d, :e)
D2 = Data.define(:x, :y); D5 = Data.define(:a, :b, :c, :d, :e)
class W5
  attr_reader :a, :b, :c, :d, :e
  def initialize(a, b, c, d, e) = (@a = a; @b = b; @c = c; @d = d; @e = e)
  def with(a: @a, b: @b, c: @c, d: @d, e: @e) = W5.new(a, b, c, d, e)
end
W5_INSTANCE = W5.new(1, 2, 3, 4, 5); D5_INSTANCE = D5.new(1, 2, 3, 4, 5)

# initialize overridden to give a default, calling super: the usual way to validate or default members
class OC; def initialize(x, y = 0) = (@x = x; @y = y); end
class OK; def initialize(x:, y: 0) = (@x = x; @y = y); end
OS = Struct.new(:x, :y) { def initialize(x, y = 0) = super(x, y) }
OSK = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y: 0) = super(x:, y:) }
OD = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
ODZ = Data.define(:x, :y) { def initialize(x:, y: 0) = super }

CASES = {
  "new 2 members"  => ["C2.new(1, 2)", "S2.new(1, 2)", "D2.new(1, 2)"],
  "new 5 members"  => ["C5.new(1, 2, 3, 4, 5)", "S5.new(1, 2, 3, 4, 5)", "D5.new(1, 2, 3, 4, 5)"],
  "new 2 keywords" => ["K2.new(x: 1, y: 2)", "S2.new(x: 1, y: 2)", "D2.new(x: 1, y: 2)"],
  "new 5 keywords" => ["K5.new(a: 1, b: 2, c: 3, d: 4, e: 5)", "S5.new(a: 1, b: 2, c: 3, d: 4, e: 5)", "D5.new(a: 1, b: 2, c: 3, d: 4, e: 5)"],
  "[] 2 members"   => ["C2.new(1, 2)", "S2[1, 2]", "D2[1, 2]"],
  "override, new(1, 2)" => ["OC.new(1, 2)", "OS.new(1, 2)", "OD.new(1, 2)"],
  "override, new(x:, y:)" => ["OK.new(x: 1, y: 2)", "OSK.new(x: 1, y: 2)", "OD.new(x: 1, y: 2)"],
  "override, new(x: 1)" => ["OK.new(x: 1)", "OSK.new(x: 1)", "OD.new(x: 1)"],
  "override zsuper, new(x:, y:)" => [nil, nil, "ODZ.new(x: 1, y: 2)"],
  "with(c: 9) of 5"  => ["W5_INSTANCE.with(c: 9)", nil, "D5_INSTANCE.with(c: 9)"],
  "with(a:, e:) of 5" => ["W5_INSTANCE.with(a: 8, e: 9)", nil, "D5_INSTANCE.with(a: 8, e: 9)"],
}

if ARGV[0] == "--cell"
  code = CASES.values[ARGV[1].to_i][ARGV[2].to_i]
  eval <<~CELL
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    def empty_loop(n) = (i = 0; while i < n; i += 1; end)
    def run(n) = (i = 0; while i < n; #{code}; i += 1; end)
    w = 0; while w < 200; empty_loop(10); run(10); w += 1; end
    base = nil; best = nil; r = 0
    while r < ROUNDS
      t = now; empty_loop(N); e = now - t; base = e if base.nil? || e < base
      t = now; run(N); e = now - t; best = e if best.nil? || e < best
      r += 1
    end
    puts (best - base).fdiv(N)
  CELL
  exit
end

jit = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? then ["--yjit"]
      elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit"]
      else [] end
# An uninstalled build has no rbconfig to ask, so the binary is given explicitly
ruby = ENV.fetch("BENCH_RUBY")
puts format("%-30s %7s %7s %7s", "", "class", "Struct", "Data")
CASES.each_with_index do |(label, codes), row|
  next unless ARGV.empty? || ARGV.any? { label.include?(_1) }
  cells = codes.each_index.map { |col| codes[col] && IO.popen([ruby, *jit, __FILE__, "--cell", row.to_s, col.to_s], err: File::NULL, &:read).to_f }
  puts format("%-30s %s", label, cells.map { _1 ? format("%7.1f", _1) : format("%7s", "-") }.join(" "))
end
