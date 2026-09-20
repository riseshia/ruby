# Data / Struct classes with an initialize written in Ruby: results, errors, backtraces,
# tracing and what initialize receives must not depend on how new reaches it.
require "objspace"
Defaulted = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
Zsuper = Data.define(:x, :y) { def initialize(x:, y: 0) = super }
Validated = Data.define(:x, :y) { def initialize(x:, y:) = (raise ArgumentError, "negative" if x < 0; super(x: x, y: y.to_s)) }
Rest = Data.define(:x, :y) { def initialize(**kw) = ($seen = kw; super(**kw)) }
Splat = Data.define(:x, :y) { def initialize(*args, **kw) = ($seen = [args, kw]; super(**kw)) }
Swapped = Data.define(:x, :y) { def initialize(x:, y:) = super(y: x, x: y) }
Partial = Data.define(:x, :y) { def initialize(x:, y:) = super(x:) }
Extra = Data.define(:x, :y) { def initialize(x:, y:) = super(x:, y:, z: 1) }
Twice = Data.define(:x, :y) { def initialize(x:, y:) = (super(x:, y:); super(x:, y:)) }
Blocky = Data.define(:x) { def initialize(x:, &blk) = super(x: blk ? blk.call(x) : x) }
WithIvar = Data.define(:x) { def initialize(x:) = (@memo = x * 2; super(x:)) }
SubOfBuiltin = Class.new(Data.define(:x, :y)) { def initialize(x:, y: 5) = super }

CASES = {
  "default filled" => -> { Defaulted.new(x: 1).to_h },
  "default overridden" => -> { Defaulted.new(x: 1, y: 2).to_h },
  "positional" => -> { Defaulted.new(1, 2).to_h },
  "positional, one" => -> { Defaulted.new(1).to_h },
  "zsuper" => -> { Zsuper.new(x: 1).to_h },
  "validation passes" => -> { Validated.new(x: 1, y: 2).to_h },
  "validation raises" => -> { Validated.new(x: -1, y: 2) },
  "validation raises, positional" => -> { Validated.new(-1, 2) },
  "missing keyword" => -> { Validated.new(x: 1) },
  "unknown keyword" => -> { Validated.new(x: 1, y: 2, z: 3) },
  "too many positional" => -> { Validated.new(1, 2, 3) },
  "**kw sees" => -> { Rest.new(x: 1, y: 2); [$seen, $seen.frozen?, $seen.class] },
  "**kw sees, positional" => -> { Rest.new(1, 2); $seen },
  "*args, **kw sees" => -> { Splat.new(x: 1, y: 2); $seen },
  "*args, **kw sees, positional" => -> { Splat.new(1, 2); $seen },
  "string keys" => -> { Rest.new("x" => 1, "y" => 2).to_h },
  "double splat" => -> { h = {x: 1, y: 2}; r = Defaulted.new(**h); [r.to_h, h] },
  "swapped" => -> { Swapped.new(x: 1, y: 2).to_h },
  "super with a member missing" => -> { Partial.new(x: 1, y: 2) },
  "super with an unknown keyword" => -> { Extra.new(x: 1, y: 2) },
  "super twice" => -> { Twice.new(x: 1, y: 2) },
  "block" => -> { Blocky.new(x: 2) { _1 * 10 }.to_h },
  "ivar before super" => -> { o = WithIvar.new(x: 2); [o.to_h, o.instance_variable_get(:@memo), o.frozen?] },
  "subclass of a built-in initialize" => -> { [SubOfBuiltin.new(x: 1).to_h, SubOfBuiltin.new(1, 2).to_h] },
  "allocation tracing" => -> { o = nil; ObjectSpace.trace_object_allocations { o = Defaulted.new(x: 1) }; ObjectSpace.allocation_method_id(o) },
  "frozen" => -> { Defaulted.new(x: 1).frozen? },
}.freeze

CASES.each do |label, body|
  result = nil
  300.times do
    result = begin
      body.call.inspect
    rescue => error
      "#{error.class}: #{error.message} #{error.backtrace_locations.first(3).map(&:label).inspect}"
    end
  end
  puts "#{label}: #{result}"
end

events = []
TracePoint.new(:c_call, :c_return, :call, :return) { |tp| events << [tp.event, tp.method_id] }.enable { Defaulted.new(x: 1); Defaulted.new(1, 2) }
puts "events: #{events.inspect}"
puts "after tracing: #{Defaulted.new(x: 1).to_h}"

Late = Data.define(:x, :y)
def make = Late.new(x: 1, y: 2)
3000.times { make }
Late.class_eval { def initialize(x:, y:) = super(x:, y: y + 100) }
puts "initialize defined later: #{make.to_h}"
3000.times { make }
Late.class_eval { remove_method :initialize }
puts "initialize removed: #{make.to_h}"
