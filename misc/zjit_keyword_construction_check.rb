# Every case runs often enough to be JIT-compiled; the printed results must be the same with
# and without a JIT.
KwPoint = Struct.new(:x, :y, :z, keyword_init: true)
AnyPoint = Struct.new(:x, :y, :z)
PosPoint = Struct.new(:x, :y, :z, keyword_init: false)
Coord = Data.define(:x, :y, :z)
class SubCoord < Coord; end
class Custom < Coord
  def initialize(x:, y:, z: 0) = super(x: x.to_s, y:, z:)
end
BigKw = Struct.new(*(1..12).map { :"m#{_1}" }, keyword_init: true)

CASES = {
  "kw struct, reordered" => -> { KwPoint.new(z: 3, x: 1, y: 2).to_a },
  "kw struct, partial" => -> { KwPoint.new(y: 2).to_a },
  "kw struct, unknown" => -> { KwPoint.new(x: 1, w: 2) },
  "kw struct, positional" => -> { KwPoint.new(1, 2) },
  "default struct, keywords" => -> { AnyPoint.new(y: 2, x: 1).to_a },
  "default struct, positional + keywords" => -> { AnyPoint.new(1, y: 2).to_a },
  "default struct, unknown keyword" => -> { AnyPoint.new(w: 1) },
  "positional-only struct, keywords" => -> { PosPoint.new(x: 1, y: 2).to_a },
  "data, reordered" => -> { Coord.new(z: 3, y: 2, x: 1).to_h },
  "data, positional" => -> { Coord.new(1, 2, 3).to_h },
  "data, missing" => -> { Coord.new(x: 1, y: 2) },
  "data, unknown" => -> { Coord.new(x: 1, y: 2, z: 3, w: 4) },
  "data, positional + keyword" => -> { Coord.new(1, 2, z: 3) },
  "data subclass" => -> { [SubCoord.new(x: 1, y: 2, z: 3).class, SubCoord.new(1, 2, 3).to_h] },
  "data with initialize" => -> { [Custom.new(x: 1, y: 2).to_h, Custom.new(1, 2, 3).to_h] },
  "data frozen" => -> { [Coord.new(x: 1, y: 2, z: 3).frozen?, Coord.new(1, 2, 3).frozen?, KwPoint.new(x: 1).frozen?] },
  "12 member kw struct" => -> { BigKw.new(m12: 12, m1: 1).to_a },
  "values kept across GC" => -> { s = KwPoint.new(x: "a" * 10, y: [1, 2], z: {k: 1}); GC.start; [s.x, s.y, s.z] },
  "re-initialize frozen" => -> { KwPoint.new(x: 1).freeze.send(:initialize, x: 2) },
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
