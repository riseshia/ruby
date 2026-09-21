# Pieces of `case o in {x:, y:}` and `in [x, y, z]` for a class, a Struct and a Data. One process per cell.
class C
  attr_reader :x, :y, :z
  def initialize(x, y, z) = (@x = x; @y = y; @z = z)
  def deconstruct_keys(keys) = {x: @x, y: @y, z: @z}
  def deconstruct = [@x, @y, @z]
end
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y, :z)
KEYS = %i[x y].freeze
NEW = ["C.new(1, 2, 3)", "S.new(1, 2, 3)", "D.new(1, 2, 3)"]
CASES = {
  "in {x:, y:}"              => "case o; in {x:, y:} then x; end",
  "in {x: Integer => a}"     => "case o; in {x: Integer => a} then a; end",
  "deconstruct_keys(KEYS)"   => "o.deconstruct_keys(KEYS)",
  "deconstruct_keys(nil)"    => "o.deconstruct_keys(nil)",
  "in [x, y, z]"             => "case o; in [x, y, z] then x; end",
  "in S/D/C(x:)"             => "case o; in KLASS(x:) then x; end",
}
if ARGV[0] == "--cell"
  code = CASES.values[ARGV[1].to_i]; col = ARGV[2].to_i
  exit if col == 2 && code.include?("[x, y, z]")
  O = eval(NEW[col]); KLASS = O.class
  eval <<~CELL
    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    def run(o, n) = (i = 0; while i < n; #{code}; i += 1; end)
    def empty(o, n) = (i = 0; while i < n; i += 1; end)
    w = 0; while w < 200; run(O, 10); empty(O, 10); w += 1; end
    best = nil; base = nil; r = 0
    while r < 5
      t = now; empty(O, 1_000_000); e = now - t; base = e if base.nil? || e < base
      t = now; run(O, 1_000_000); e = now - t; best = e if best.nil? || e < best
      r += 1
    end
    puts (best - base).fdiv(1_000_000)
  CELL
  exit
end
jit = if defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? then ["--yjit"] elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit"] else [] end
ruby = ENV.fetch("BENCH_RUBY")
puts format("%-26s %7s %7s %7s", "", "class", "Struct", "Data")
CASES.each_key.with_index do |label, row|
  cells = (0..2).map { |col| out = IO.popen([ruby, "--disable-gems", *jit, __FILE__, "--cell", row.to_s, col.to_s], err: File::NULL, &:read); out.empty? ? nil : out.to_f }
  puts format("%-26s %s", label, cells.map { _1 ? format("%7.1f", _1) : format("%7s", "-") }.join(" "))
end
