# Struct / Data classes defined inside a Ruby::Box, and instances crossing the boundary.
# Usage: RUBY_BOX=1 ruby box_check.rb
File.write("#{__dir__}/box_lib.rb", <<~LIB)
  module BoxLib
    Inner = Struct.new(:a, :b)
    InnerKw = Struct.new(:a, :b, keyword_init: true) { def initialize(a:, b: 0) = super }
    InnerData = Data.define(:a, :b) { def initialize(a:, b: 0) = super }
    def self.build = [Inner.new(1, 2).to_a, Inner.new(1).inspect, InnerKw.new(a: 1).to_h, InnerData.new(a: 1).to_h, InnerData.new(1, 2).inspect,
                      Inner.new(1, 2) == Inner.new(1, 2), {InnerData.new(a: 1) => 1}[InnerData.new(a: 1)], InnerData.new(a: 1).with(b: 5).to_h]
    def self.use(s, d) = [s.to_a, s.x, s[:y], s.size, s.to_h, s.inspect, d.to_h, d.with(y: 9).to_h, d.class.new(x: 7, y: 8).to_h, s.class.new(5, 6).to_a]
    def self.make = [Inner.new(1, 2), InnerData.new(a: 3)]
  end
LIB
Outer = Struct.new(:x, :y); OuterData = Data.define(:x, :y)
box = Ruby::Box.new
box.require("#{__dir__}/box_lib.rb")
lib = box::BoxLib
result = nil
300.times { result = [lib.build, lib.use(Outer.new(1, 2), OuterData.new(3, 4))] }
p result
s, d = lib.make
300.times { result = [s.to_a, s.a, s[:b], s.to_h, s.inspect, d.to_h, d.with(b: 1).to_h, d.inspect, s.class.new(9).to_a, d.class.new(a: 1).to_h] }
p result
p [Outer.new(1, 2).to_a, OuterData.new(x: 1, y: 2).to_h]
