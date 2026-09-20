# Data#with, run often enough to be JIT-compiled; results must match the interpreter.
require "objspace"
Coord = Data.define(:x, :y, :z)
class SubCoord < Coord; end
class Validated < Coord
  def initialize(x:, y:, z:) = super(x: x.abs, y:, z:)
end
BigData = Data.define(*(1..12).map { :"m#{_1}" })

CASES = {
  "one member" => -> { Coord.new(1, 2, 3).with(y: 5).to_h },
  "all members, reordered" => -> { Coord.new(1, 2, 3).with(z: 9, x: 7, y: 8).to_h },
  "original untouched, copy frozen" => -> { c = Coord.new(1, [2], 3); d = c.with(x: 0); [c.to_h, d.frozen?, d.y.equal?(c.y), d.equal?(c)] },
  "no arguments returns self" => -> { c = Coord.new(1, 2, 3); c.with.equal?(c) },
  "unknown keyword" => -> { Coord.new(1, 2, 3).with(w: 1) },
  "positional argument" => -> { Coord.new(1, 2, 3).with(1) },
  "string key" => -> { Coord.new(1, 2, 3).with("y" => 5).to_h },
  "double splat" => -> { h = {y: 5}; Coord.new(1, 2, 3).with(**h).to_h },
  "subclass keeps its class" => -> { d = SubCoord.new(1, 2, 3).with(z: 0); [d.class, d.to_h] },
  "initialize is called when defined" => -> { Validated.new(1, 2, 3).with(x: -5).to_h },
  "12 members" => -> { BigData.new(*1..12).with(m12: 0, m1: 0).to_h.values },
  "young values survive GC" => -> { d = Coord.new(1, 2, 3).with(x: "a" * 30, y: [1, [2]]); GC.start; [d.x, d.y, d.z] },
  "ivars are not copied" => -> { c = Coord.new(1, 2, 3); c.with(x: 0).instance_variables },
  "allocation tracing" => -> { o = nil; ObjectSpace.trace_object_allocations { o = Coord.new(1, 2, 3).with(x: 0) }; ObjectSpace.allocation_method_id(o) },
}.freeze
CASES.each do |label, body|
  result = nil
  300.times do
    result = begin
      body.call.inspect
    rescue => error
      "#{error.class}: #{error.message} #{error.backtrace_locations.first(2).map(&:label).inspect}"
    end
  end
  puts "#{label}: #{result}"
end

Late = Data.define(:x, :y)
def update(d) = d.with(y: 0)
3000.times { update(Late.new(1, 2)) }
Late.class_eval { def initialize(x:, y:) = super(x:, y: y + 100) }
puts "after initialize is defined: #{update(Late.new(1, 2)).to_h}"
