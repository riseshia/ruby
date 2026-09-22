# ns per construction across member counts and call styles, against a hand-written class.
#
# Columns: class (initialize written by hand, positional or keyword to match the style),
# Struct, Struct with keyword_init: true, Data. Rows: member count x call style.
# Every cell runs in its own process (a JIT specializes shared call sites and only counts
# calls coming from the interpreter; an earlier cell leaves a bigger heap). Inside a cell
# everything is straight-line top-level code.
#
# Usage: BENCH_RUBY=path/to/ruby ruby [--yjit|--zjit] initialize_matrix_bench.rb [row filter...]
N = 2_000_000
ROUNDS = 7
SIZES = [1, 3, 8, 16]
NAMES = (:a..:z).to_a

SIZES.each do |n|
  names = NAMES.first(n)
  params = names.join(", ")
  body = names.map { "@#{_1} = #{_1}" }.join("; ")
  eval "class C#{n}; def initialize(#{params}) = (#{body}); end"
  eval "class K#{n}; def initialize(#{names.map { "#{_1}:" }.join(", ")}) = (#{body}); end"
  Object.const_set(:"S#{n}", Struct.new(*names))
  Object.const_set(:"SK#{n}", Struct.new(*names, keyword_init: true))
  Object.const_set(:"D#{n}", Data.define(*names))
  Object.const_set(:"A#{n}", (1..n).to_a.freeze)
  Object.const_set(:"H#{n}", names.each_with_index.to_h { |k, i| [k, i + 1] }.freeze)
end

def args(n) = (1..n).to_a.join(", ")
def kwargs(n) = NAMES.first(n).each_with_index.map { |k, i| "#{k}: #{i + 1}" }.join(", ")

# style => [class, Struct, Struct(keyword_init), Data]
STYLES = {
  "new(pos)"  => ->(n) { ["C#{n}.new(#{args(n)})", "S#{n}.new(#{args(n)})", nil, "D#{n}.new(#{args(n)})"] },
  "new(kw)"   => ->(n) { ["K#{n}.new(#{kwargs(n)})", nil, "SK#{n}.new(#{kwargs(n)})", "D#{n}.new(#{kwargs(n)})"] },
  "new(*ary)" => ->(n) { ["C#{n}.new(*A#{n})", "S#{n}.new(*A#{n})", nil, "D#{n}.new(*A#{n})"] },
  "new(**h)"  => ->(n) { ["K#{n}.new(**H#{n})", nil, "SK#{n}.new(**H#{n})", "D#{n}.new(**H#{n})"] },
  "[]"        => ->(n) { [nil, "S#{n}[#{args(n)}]", nil, "D#{n}[#{args(n)}]"] },
}
CASES = SIZES.flat_map { |n| STYLES.map { |style, f| ["#{n} #{style}", f.(n)] } }.to_h

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
      elsif defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled? then ["--zjit", "--zjit-call-threshold=2", "--zjit-num-profiles=1"]
      else [] end
ruby = ENV.fetch("BENCH_RUBY")
puts format("%-14s %7s %7s %7s %7s", "members/style", "class", "Struct", "StructK", "Data")
CASES.each_with_index do |(label, codes), row|
  next unless ARGV.empty? || ARGV.any? { label.include?(_1) }
  cells = codes.each_index.map { |col| codes[col] && IO.popen([ruby, *jit, __FILE__, "--cell", row.to_s, col.to_s], err: File::NULL, &:read).to_f }
  puts format("%-14s %s", label, cells.map { _1 ? format("%7.1f", _1) : format("%7s", "-") }.join(" "))
end
