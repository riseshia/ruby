module BoxLib
  Inner = Struct.new(:a, :b)
  InnerKw = Struct.new(:a, :b, keyword_init: true) { def initialize(a:, b: 0) = super }
  InnerData = Data.define(:a, :b) { def initialize(a:, b: 0) = super }
  def self.build = [Inner.new(1, 2).to_a, Inner.new(1).inspect, InnerKw.new(a: 1).to_h, InnerData.new(a: 1).to_h, InnerData.new(1, 2).inspect,
                    Inner.new(1, 2) == Inner.new(1, 2), {InnerData.new(a: 1) => 1}[InnerData.new(a: 1)], InnerData.new(a: 1).with(b: 5).to_h]
  def self.use(s, d) = [s.to_a, s.x, s[:y], s.size, s.to_h, s.inspect, d.to_h, d.with(y: 9).to_h, d.class.new(x: 7, y: 8).to_h, s.class.new(5, 6).to_a]
  def self.make = [Inner.new(1, 2), InnerData.new(a: 3)]
end
