# Cost of defining classes: Struct.new / Data.define against Class.new with attr_accessor.
# aws-sdk alone defines well over a thousand Struct classes at load time.
# Usage: ruby struct_define_bench.rb
MEMBERS = {3 => %i[a b c], 12 => (1..12).map { :"m#{_1}" }, 30 => (1..30).map { :"m#{_1}" }}.freeze
DEFINITIONS = 20_000
ROUNDS = 5

def measure_us
  ROUNDS.times.map {
    GC.start
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    DEFINITIONS.times { yield }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t).fdiv(DEFINITIONS) / 1000
  }.min
end

puts format("%-10s %22s %12s %12s %24s", "members", "Class.new+attr_accessor", "Struct.new", "Data.define", "Struct.new keyword_init")
MEMBERS.each do |count, names|
  cells = [
    measure_us { Class.new { attr_accessor(*names) } },
    measure_us { Struct.new(*names) },
    measure_us { Data.define(*names) },
    measure_us { Struct.new(*names, keyword_init: true) },
  ]
  puts format("%-10d %19.2fus %10.2fus %10.2fus %22.2fus", count, *cells)
end
