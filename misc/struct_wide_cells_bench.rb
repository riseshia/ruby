# ns/op for a 12-member record: are there cliffs past the sizes the other benches use?
# Usage: ruby [--yjit|--zjit] wide_cells.rb OP class|struct|data
N = Integer(ENV.fetch("N", "12"))
NAMES = Array.new(N) { :"m#{_1}" }
class Plain
  attr_reader(*NAMES)
  eval "def initialize(#{NAMES.join(', ')}) = (#{NAMES.map { "@#{_1} = #{_1}" }.join('; ')})"
  eval "def to_h = { #{NAMES.map { "#{_1}: @#{_1}" }.join(', ')} }"
  eval "def ==(o) = o.class == self.class && #{NAMES.map { "@#{_1} == o.#{_1}" }.join(' && ')}"
  eval "def hash = [#{NAMES.map { "@#{_1}" }.join(', ')}].hash"
  alias eql? ==
  eval "def deconstruct_keys(keys) = to_h"
end
class PlainKw
  attr_reader(*NAMES)
  eval "def initialize(#{NAMES.map { "#{_1}:" }.join(', ')}) = (#{NAMES.map { "@#{_1} = #{_1}" }.join('; ')})"
end
KIND = ARGV.fetch(1)
KLASS = { "class" => Plain, "struct" => Struct.new(*NAMES), "data" => Data.define(*NAMES) }.fetch(KIND)
KWKLASS = KIND == "class" ? PlainKw : KLASS
ARGS = (1..N).to_a.join(", "); KWARGS = NAMES.each_with_index.map { |n, i| "#{n}: #{i + 1}" }.join(", ")
H = NAMES.each_with_index.to_h { |n, i| [n, i + 1] }; A = (1..N).to_a
OPS = {
  "new" => "KLASS.new(#{ARGS}).m#{N - 1}", "new_kw" => "KWKLASS.new(#{KWARGS}).m#{N - 1}", "new_hash" => "KWKLASS.new(**H).m#{N - 1}", "new_splat" => "KLASS.new(*A).m#{N - 1}",
  "to_h" => "o.to_h.size", "eq" => "o == O2 ? 1 : 2", "hash_key" => "HK[o]", "reader_last" => "o.m#{N - 1}", "aref_sym" => "o[:m#{N - 1}]",
  "pattern" => "case o; in {m0:, m#{N - 1}:} then m#{N - 1}; end", "inspect" => "o.inspect.size", "with" => "o.with(m#{N - 1}: 0).m0",
}
op = OPS.fetch(ARGV.fetch(0))
eval "def run(o, n) = (i = 0; r = 0; while i < n; r = (#{op}); i += 1; end; r)"
o = KLASS.new(*A); O2 = KLASS.new(*A); HK = { O2 => 1 }
begin; run(o, 1); rescue NoMethodError, ArgumentError, TypeError, NoMatchingPatternError; puts format("%-12s %-7s      -", ARGV[0], KIND); exit; end
w = 0; while w < 300; run(o, 20); w += 1; end
n = 2_000_000
t = Process.clock_gettime(Process::CLOCK_MONOTONIC); run(o, n)
printf "%-12s %-7s %6.1f\n", ARGV[0], KIND, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) / n * 1e9
