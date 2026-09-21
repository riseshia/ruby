# ns per comparison, one process per cell. class: hand-written == / eql? / hash over three readers.
class C
  attr_reader :x, :y, :z
  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def ==(other) = other.class == self.class && @x == other.x && @y == other.y && @z == other.z
  def eql?(other) = other.class == self.class && @x.eql?(other.x) && @y.eql?(other.y) && @z.eql?(other.z)
  def hash = [self.class, @x, @y, @z].hash
end
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y, :z)
KLASSES = [C, S, D]
CASES = {
  "== equal, ints"           => ["K.new(1, 2, 3)", "K.new(1, 2, 3)", "a == b"],
  "== differs in last, ints" => ["K.new(1, 2, 3)", "K.new(1, 2, 4)", "a == b"],
  "== differs in first"      => ["K.new(1, 2, 3)", "K.new(9, 2, 3)", "a == b"],
  "== equal, frozen strings" => ['K.new("a".freeze, "bb".freeze, :c)', 'K.new("a".freeze, "bb".freeze, :c)', "a == b"],
  "== differs, strings"      => ['K.new("a", "bb", "cc")', 'K.new("a", "bb", "cd")', "a == b"],
  "eql? equal"               => ["K.new(1, 2, 3)", "K.new(1, 2, 3)", "a.eql?(b)"],
  "eql? differs"             => ["K.new(1, 2, 3)", "K.new(1, 2, 4)", "a.eql?(b)"],
  "hash"                     => ["K.new(1, 2, 3)", "nil", "a.hash"],
  "Hash lookup"              => ["{K.new(1, 2, 3) => 1}", "K.new(1, 2, 3)", "a[b]"],
  "Array#include? (10, miss)" => ["Array.new(10) { |i| K.new(i, 2, 3) }", "K.new(99, 2, 3)", "a.include?(b)"],
}
if ARGV[0] == "--cell"
  K = KLASSES[ARGV[2].to_i]
  setup = CASES.values[ARGV[1].to_i]
  A = eval(setup[0]); B = eval(setup[1])
  eval <<~CELL
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    def run(a, b, n) = (i = 0; while i < n; #{setup[2]}; i += 1; end)
    def empty(a, b, n) = (i = 0; while i < n; i += 1; end)
    w = 0; while w < 200; run(A, B, 10); empty(A, B, 10); w += 1; end
    best = nil; base = nil; r = 0
    while r < 5
      t = now; empty(A, B, 2_000_000); e = now - t; base = e if base.nil? || e < base
      t = now; run(A, B, 2_000_000); e = now - t; best = e if best.nil? || e < best
      r += 1
    end
    puts (best - base).fdiv(2_000_000)
  CELL
  exit
end
jit = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? then ["--yjit"] elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit"] else [] end
ruby = ENV.fetch("BENCH_RUBY")
puts format("%-28s %7s %7s %7s", "", "class", "Struct", "Data")
CASES.each_key.with_index do |label, row|
  cells = (0..2).map { |col| IO.popen([ruby, "--disable-gems", *jit, __FILE__, "--cell", row.to_s, col.to_s], err: File::NULL, &:read).to_f }
  puts format("%-28s %s", label, cells.map { format("%7.1f", _1) }.join(" "))
end
