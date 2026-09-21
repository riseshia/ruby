# K.new(**hash) from hot call sites: the Hash is read where it is, so it must come out unchanged,
# and every way the keys can be wrong has to raise what it raised before.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message.gsub(/0x\h+/, '0x')}")
D = Data.define(:x, :y, :z); S = Struct.new(:x, :y, :z); Kw = Struct.new(:x, :y, :z, keyword_init: true); Pos = Struct.new(:x, :y, :z, keyword_init: false)
DOver = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x: x * 2, y:) }
SOver = Struct.new(:x, :y) { def initialize(**kw) = super(**kw.transform_values { _1.to_s }) }
Big = Data.define(*Array.new(20) { :"m#{_1}" }); BigS = Struct.new(*Array.new(20) { :"m#{_1}" })
class HashLike; def to_hash = { x: 1, y: 2, z: 3 }; end
def d(h) = D.new(**h)
def s(h) = S.new(**h)
def kw(h) = Kw.new(**h)
def pos(h) = Pos.new(**h)
def dover(h) = DOver.new(**h)
def sover(h) = SOver.new(**h)
def big(h) = Big.new(**h)
def bigs(h) = BigS.new(**h)
def d_mut(h) = D.new(**h, z: 9)
def d_two(a, b) = D.new(**a, **b)
def d_block(h) = D.new(**h) { :ignored }
def d_pos_and_kw(h) = D.new(1, **h)
def any(k, h) = k.new(**h)
full = { x: 1, y: "two", z: [3] }.freeze
400.times { d(full); s(full); kw(full); pos(full) rescue nil; dover({ x: 1 }); sover({ x: 1 }); d_mut({ x: 1, y: 2 }); d_two({ x: 1 }, { y: 2, z: 3 }); any(D, full); any(S, full) }
CASES = {
  "full" => { x: 1, y: "two", z: [3] }, "reordered" => { z: 3, x: 1, y: 2 }, "missing" => { x: 1 }, "empty" => {}, "unknown" => { x: 1, y: 2, z: 3, w: 4 },
  "only unknown" => { w: 1 }, "string keys" => { "x" => 1, "y" => 2, "z" => 3 }, "mixed keys" => { x: 1, "y" => 2, z: 3 }, "integer key" => { 0 => 1 },
  "default proc" => Hash.new { |_, k| k }.merge(x: 1, y: 2, z: 3), "identity" => { x: 1, y: 2, z: 3 }.compare_by_identity, "nil values" => { x: nil, y: nil, z: nil },
}
CASES.each do |name, h|
  before = h.dup
  report("#{name}") { [:d, :s, :kw, :pos].map { |m| (r = send(m, h); [r, r.frozen?, r.to_a.map(&:object_id) == r.members.map { h[_1].object_id }]) rescue "#{$!.class}: #{$!.message}" } }
  report("#{name} hash untouched") { [h == before, h.size, h.frozen?, h.default_proc.nil?, h.compare_by_identity?] }
end
report("not a Hash") { [(d(nil) rescue $!.class), (d(HashLike.new)), (s(HashLike.new)), (d(1) rescue $!.class), (d([[:x, 1]]) rescue $!.class)] }
report("hash subclass") { k = Class.new(Hash); h = k[x: 1, y: 2, z: 3]; [d(h), s(h), h.class == k] }
report("overridden initialize") { [dover({ x: 2 }), dover({ x: 2, y: 5 }), sover({ x: 1, y: 2 }), (dover({ y: 1 }) rescue $!.class)] }
report("many members") { h = Array.new(20) { [:"m#{_1}", _1] }.to_h; [big(h).m19, bigs(h).m19, bigs({ m3: 3 }).to_a.compact, (big({ m0: 1 }) rescue $!.class)] }
report("merged at the call site") { [d_mut({ x: 1, y: 2 }), d_two({ x: 1 }, { y: 2, z: 3 }), (d_two({ x: 1 }, { x: 2, y: 2, z: 3 }))] }
report("with a block / positional") { [d_block(full), (d_pos_and_kw({ y: 2, z: 3 }) rescue "#{$!.class}: #{$!.message}")] }
report("polymorphic site") { [D, S, Kw, DOver, Class.new(D), Class.new(S)].map { |k| any(k, k.members.to_h { [_1, 1] }) rescue $!.class } }
report("values kept alive and shared") { v = "young #{rand}"; o = d({ x: v, y: v, z: v }); GC.start; [o.x.equal?(v), o.y.equal?(o.z)] }
report("frozen struct re-initialized") { o = S.new(1, 2, 3).freeze; (o.send(:initialize, **full) rescue $!.class) }
report("struct re-initialized") { o = S.new(1, 2, 3); h = { y: :only }; o.send(:initialize, **h); o }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { d(full); s(full) }
report("traced") { events }
ObjectSpace.trace_object_allocations { o = d(full); p2 = s(full); report("allocation tracing") { [ObjectSpace.allocation_method_id(o), ObjectSpace.allocation_method_id(p2)] } }
400.times { d(full); s(full) }
GC.stress = true; ok = 25.times.all? { |i| d({ x: i, y: [i], z: "s#{i}" }).y == [i] && s({ y: "v#{i}" }).y == "v#{i}" && kw(full).z == [3] }; GC.stress = false
report("gc stress") { ok }
GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("after compaction") { [d(full), s(full)] }
class D; def initialize(**kw) = super(**kw.transform_values { [_1] }); end
report("initialize defined later") { d(full) }
