# Point.new(*row) and data.with(**hash) from hot call sites, with every kind of Array and Hash.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message.gsub(/0x\h+/, '0x')}")
def attempt = yield rescue "#{$!.class}: #{$!.message}"
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y, :z); Kw = Struct.new(:x, :y, :z, keyword_init: true); Pos = Struct.new(:x, :y, :z, keyword_init: false)
SOver = Struct.new(:x, :y) { def initialize(*a) = super(*a.map(&:to_s)) }
DOver = Data.define(:x, :y) { def initialize(x:, y: :dflt) = super }
class ArrayLike; def to_a = [7, 8, 9]; end
def s(a) = S.new(*a)
def d(a) = D.new(*a)
def kw(a) = Kw.new(*a)
def pos(a) = Pos.new(*a)
def sover(a) = SOver.new(*a)
def dover(a) = DOver.new(*a)
def s_more(a) = S.new(0, *a)
def s_two(a, b) = S.new(*a, *b)
def s_kw(a, h) = S.new(*a, **h)
def s_blk(a) = S.new(*a) { :ignored }
def aref(a) = S[*a]
def with_h(o, h) = o.with(**h)
def with_mut(o, h) = o.with(**h, z: :lit)
def with_blk(o, h) = o.with(**h) { 1 }
def flagged(*a) = a
ruby2_keywords :flagged
row = [1, "two", [3]].freeze; o = D.new(1, 2, 3)
400.times { s(row); d(row); pos(row); sover([1, 2]); dover([1, 2]); s_more([1, 2]); s_two([1], [2, 3]); aref(row); with_h(o, { y: 5 }); with_mut(o, { y: 5 }); kw(row) rescue nil }
ARRAYS = { "full" => [1, "two", [3]], "short" => [1], "empty" => [], "too many" => [1, 2, 3, 4], "hash last" => [1, 2, { z: 3 }], "only hash" => [{ x: 1, y: 2, z: 3 }],
           "flagged hash last" => flagged(1, 2, z: 3), "only flagged hash" => flagged(x: 1, y: 2, z: 3), "nil" => nil, "scalar" => 5, "array like" => ArrayLike.new, "nested" => [[1, 2, 3]] }
ARRAYS.each do |name, a|
  before = a.dup rescue a
  report(name) { [:s, :d, :kw, :pos, :aref].map { |m| attempt { r = send(m, a); [r, r.frozen?] } } }
  report("#{name} untouched") { [a == before, (a.frozen? if a.respond_to?(:frozen?))] }
end
report("values are the same objects") { v = "young #{rand}"; a = [v, v, v]; [s(a).x.equal?(v), d(a).z.equal?(v)] }
report("overridden initialize") { [sover([1, 2]), dover([1, 2]), dover([1]), attempt { dover([]) }] }
report("splat with other arguments") { [s_more([1, 2]), s_two([1], [2, 3]), attempt { s_kw([1], { y: 2 }) }, s_blk(row)] }
report("polymorphic site") { def any(k, a) = k.new(*a); [S, D, Pos, SOver, Array, String, Class.new(S), Class.new(D)].map { |k| attempt { any(k, k == String ? ["s"] : [1, 2, 3].first(k.respond_to?(:members) ? k.members.size : 1)) } } }
HASHES = { "one" => { y: 5 }, "all" => { x: 7, y: 8, z: 9 }, "empty" => {}, "unknown" => { w: 1 }, "string key" => { "y" => 5 }, "mixed" => { y: 5, "z" => 6 }, "default proc" => Hash.new { 1 }.merge(y: 5), "nil" => nil }
HASHES.each do |name, h|
  before = h.dup
  report("with #{name}") { [attempt { r = with_h(o, h); [r, r.frozen?, r.equal?(o)] }, attempt { with_mut(o, h) }, attempt { with_blk(o, h) }, h == before] }
end
DW = Data.define(:x, :y) { def initialize(x:, y:) = super(x: x.to_s, y:) }
def with_over(o, h) = o.with(**h)
ow = DW.new(x: 1, y: 2); 300.times { with_over(ow, { y: 3 }) }
report("with, overridden initialize") { [with_over(ow, { y: 3 }), with_over(ow, { x: 9 })] }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { s(row); d(row); with_h(o, { y: 5 }) }
report("traced") { events }
ObjectSpace.trace_object_allocations { a = d(row); b = with_h(o, { y: 1 }); c = s(row); report("allocation tracing") { [a, b, c].map { ObjectSpace.allocation_method_id(_1) } } }
400.times { s(row); d(row); with_h(o, { y: 5 }) }
GC.stress = true; ok = 25.times.all? { |i| d([i, [i], "s#{i}"]).y == [i] && s(["v#{i}"]).x == "v#{i}" && with_h(o, { z: [i] }).z == [i] }; GC.stress = false
report("gc stress") { ok }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [s(row), d(row), with_h(o, { x: 0 })] }
class S; def initialize(*a) = super(*a.reverse); end
report("initialize defined later") { s(row) }
