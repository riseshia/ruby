# `super(x:, y:)` from an overridden initialize into Struct#initialize / Data#initialize,
# run often enough to be JIT-compiled.
SK = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y: 0) = super(x:, y:) }
SN = Struct.new(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }             # keyword_init unset
SF = Struct.new(:x, :y, keyword_init: false) { def initialize(x:, y: 0) = super(x:, y:) } # Hash becomes x
SPartial = Struct.new(:x, :y, keyword_init: true) { def initialize(x:) = super(x:) }
SUnknown = Struct.new(:x, :y, keyword_init: true) { def initialize(x:) = super(x:, z: 1) }
SDup = Struct.new(:x, :y, keyword_init: true) { def initialize(x:) = super(y: x, x: x) }
SFrozen = Struct.new(:x, keyword_init: true) { def initialize(x:) = (freeze; super(x:)) }
SBlock = Struct.new(:x, keyword_init: true) { def initialize(x:, &blk) = super(x: blk.call(x)) }
SBase = Struct.new(:x, :y, keyword_init: true)
module Doubling; def initialize(x:, y:) = super(x: x * 2, y: y * 2); end
SPrepended = Class.new(SBase) { prepend Doubling }
SIncludedA = Class.new(SBase) { include Doubling }
SIncludedB = Class.new(Struct.new(:y, :x, :z, keyword_init: true)) { include Doubling } # same method, other layout
Big = Struct.new(*(1..10).map { :"m#{_1}" }, keyword_init: true) { def initialize(**kw) = super(m1: 1, m2: 2, m3: 3, m4: 4, m5: 5, m6: 6, m7: 7, m8: 8, m9: 9, m10: kw[:m10]) }
DBase = Data.define(:x, :y)
DIncludedA = Class.new(DBase) { include Doubling }
DIncludedB = Class.new(Data.define(:y, :x)) { include Doubling }
DFrozen = Data.define(:x) { def initialize(x:) = (super(x:); super(x:)) }

CASES = {
  "kw true" => -> { SK.new(x: 1).to_a },
  "kw unset" => -> { SN.new(x: 1, y: 2).to_a },
  "kw false" => -> { SF.new(x: 1, y: 2).to_a },
  "partial" => -> { SPartial.new(x: 1).to_a },
  "unknown" => -> { SUnknown.new(x: 1) },
  "reordered" => -> { SDup.new(x: 1).to_a },
  "frozen" => -> { SFrozen.new(x: 1) },
  "block" => -> { SBlock.new(x: 2) { _1 + 1 }.to_a },
  "prepended" => -> { SPrepended.new(x: 1, y: 2).to_a },
  "one method, two layouts" => -> { [SIncludedA.new(x: 1, y: 2).to_a, SIncludedB.new(x: 1, y: 2).to_a, SIncludedA.new(x: 3, y: 4).to_a] },
  "ten members" => -> { Big.new(m10: :last).to_a },
  "data, one method, two layouts" => -> { [DIncludedA.new(x: 1, y: 2).to_h, DIncludedB.new(x: 1, y: 2).to_h, DIncludedA.new(x: 3, y: 4).to_h] },
  "data, super twice" => -> { DFrozen.new(x: 1) },
  "young values" => -> { s = SK.new(x: "a" * 40, y: [1, [2]]); GC.start; s.to_a },
}.freeze

CASES.each do |label, body|
  result = nil
  400.times do
    result = begin
      body.call.inspect
    rescue => error
      "#{error.class}: #{error.message} #{error.backtrace_locations.first(3).map(&:label).inspect}"
    end
  end
  puts "#{label}: #{result}"
end

events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { SK.new(x: 1) }
puts "events: #{events.inspect}"
puts "after tracing: #{SK.new(x: 1).to_a}"

Late = Struct.new(:x, :y, keyword_init: true) { def initialize(x:, y:) = super(x:, y:) }
def make = Late.new(x: 1, y: 2)
3000.times { make }
Struct.class_eval { alias_method :__orig_initialize, :initialize; def initialize(*a, **kw) = __orig_initialize(**kw.transform_values { _1 + 100 }) }
puts "Struct#initialize redefined: #{make.to_a}"
