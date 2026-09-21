# One call site reaching Struct#initialize for classes that differ in keyword_init: the
# interpreter picks its handler per call cache, which must never serve the wrong kind of class.
Pos = Struct.new(:a, :b); Kw = Struct.new(:a, :b, keyword_init: true); Unset = Struct.new(:a, :b)
SubPos = Class.new(Pos); SubKw = Class.new(Kw)
module PassTwo; def initialize(a, b) = super(a, b); end
module PassHash; def initialize(h) = super(h); end
ModPos = Class.new(Struct.new(:a, :b)) { include PassTwo }
ModKw = Class.new(Struct.new(:a, :b, keyword_init: true)) { include PassTwo }
HashPos = Class.new(Struct.new(:a, :b)) { include PassHash }
HashKw = Class.new(Struct.new(:a, :b, keyword_init: true)) { include PassHash }
def make(klass, x, y) = klass.new(x, y)
def make_hash(klass, h) = klass.new(h)
def attempt = yield.to_a rescue "#{$!.class}: #{$!.message}"
order = [Pos, Kw, Unset, SubPos, SubKw, ModPos, ModKw]
3.times do |round|
  order.rotate(round).each { |k| 50.times { attempt { make(k, 1, 2) } } }
end
order.each { |k| puts "#{k.name}: #{attempt { make(k, 1, 2) }.inspect}" }
[Pos, Kw, Unset, HashPos, HashKw].each { |k| 50.times { attempt { make_hash(k, {a: 1, b: 2}) } }; puts "#{k.name} with a Hash: #{attempt { make_hash(k, {a: 1, b: 2}) }.inspect}" }
s = Pos.new(1, 2)
[Pos, Kw].each { |k| o = k.allocate; 40.times { attempt { o.send(:initialize, 3, 4); o } }; puts "#{k.name} re-initialize: #{attempt { o.send(:initialize, 3, 4); o }.inspect}" }
frozen = Pos.new(1, 2).freeze
puts "frozen: #{attempt { frozen.send(:initialize, 1, 2); frozen }.inspect}"
puts "too many: #{attempt { Pos.new(1, 2, 3) }.inspect}"
