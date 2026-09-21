# deconstruct_keys with every kind of key list, and the patterns that call it, from hot sites.
require "objspace"
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, "0x")}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y, :z); Kw = Struct.new(:x, :y, :z, keyword_init: true)
Big = Struct.new(*Array.new(12) { :"m#{_1}" }); BigD = Data.define(*Array.new(12) { :"m#{_1}" })
class ToInt; def to_int = 1; end
LISTS = [
  [], [:x], [:x, :y], [:y, :x], [:x, :y, :z], [:z, :z], [:x, :y, :x], [:x, :nope, :y], [:nope], [:nope, :x],
  [:x, :y, :z, :w], ["x"], ["x", :y], [:x, "y"], [:x, "nope", :y], [0], [:x, 1], [1, :x], [-1], [5], [:x, 5, :y], [ToInt.new], [:x, ToInt.new],
  [nil], [:x, nil], [1.5], [:x, Object.new], %i[m0 m1 m2 m3 m4 m5 m6 m7], %i[m0 m1 m2 m3 m4 m5 m6 m7 m8], %i[m11 m0], %i[m0 m0],
]
OBJS = { struct: S.new(1, "two", [3]), data: D.new(1, "two", [3]), kw: Kw.new(x: 1, y: "two", z: [3]), big: Big.new(*0...12), big_data: BigD.new(*0...12) }
def dk(o, keys) = o.deconstruct_keys(keys)
def render(o, keys) = (h = dk(o, keys); [h, h.keys.map(&:class).uniq, h.size]) rescue "#{$!.class}: #{$!.message.gsub(/0x\h+/, '0x')}"
300.times { OBJS.each_value { |o| dk(o, [:x, :y]); dk(o, [:m0, :m1]); dk(o, nil) } }
OBJS.each { |name, o| LISTS.each { |keys| report("#{name} #{keys.map { _1.is_a?(ToInt) || _1.class == Object ? _1.class : _1 }.inspect}") { render(o, keys) } } }
report("nil") { OBJS.transform_values { dk(_1, nil) } }
report("not an array") { OBJS.transform_values { |o| [(dk(o, :x) rescue $!.class), (dk(o, "x") rescue $!.class), (dk(o, {x: 1}) rescue $!.class)] } }
report("result is an ordinary Hash") { h = dk(OBJS[:struct], [:x, :y]); h[:w] = 1; h.delete(:x); 10.times { |i| h[:"k#{i}"] = i }; [h.size, h[:y], h[:k9], h.keys.first, dk(OBJS[:struct], [:x, :y]), h.frozen?, h.default] }
report("same as a literal") { h = dk(OBJS[:data], [:y, :x]); g = { y: "two", x: 1 }; [h == g, h.hash == g.hash, h.eql?(g), h.to_a == g.to_a, ObjectSpace.memsize_of(h) == ObjectSpace.memsize_of(OBJS[:data].to_h.slice(:y, :x)) || :size_differs_from_slice] }
report("keys array untouched") { keys = [:x, :y]; dk(OBJS[:struct], keys); [keys, keys.frozen?] }
def m_two(o) = (case o; in {x:, y:} then [x, y]; end)
def m_typed(o) = (case o; in {x: Integer => a, z: [b]} then [a, b]; else :no; end)
def m_rest(o) = (case o; in {x:, **rest} then [x, rest]; end)
def m_nil_rest(o) = (case o; in {x:, y:, z:, **nil} then :exact; else :no; end)
def m_const(o) = (case o; in S(x:) then [:s, x]; in D(y:) then [:d, y]; in Kw(z:) then [:kw, z]; else :other; end)
def m_missing(o) = (case o; in {x:, w:} then :has_w; in {x:} then [:only_x, x]; end)
def m_in(o) = (o in {y: String})
def m_rightward(o) = (o => {z:}; z)
def m_find(list) = (case list; in [*, {x: 2 => found}, *] then found; else :none; end)
small = OBJS.slice(:struct, :data, :kw)
300.times { small.each_value { |o| m_two(o); m_typed(o); m_rest(o); m_nil_rest(o); m_const(o); m_missing(o); m_in(o); m_rightward(o) } }
report("patterns") { small.transform_values { |o| [m_two(o), m_typed(o), m_rest(o), m_nil_rest(o), m_const(o), m_missing(o), m_in(o), m_rightward(o)] } }
report("pattern misses") { [(m_two(Big.new) rescue $!.class), m_typed(S.new("s", 2, 3)), m_const(Big.new), m_find([S.new(1, 0, 0), D.new(2, 0, 0)]), m_find([S.new(1, 0, 0)])] }
GC.stress = true; ok = 30.times.all? { |i| dk(OBJS[:struct], [:z, :x]) == { z: [3], x: 1 } && m_two(OBJS[:data]) == [1, "two"] && m_rest(OBJS[:kw]) == [1, { y: "two", z: [3] }] }; GC.stress = false
report("gc stress") { ok }
keep = Array.new(100) { |i| dk(S.new("young#{i}", [i], i), [:x, :y]) }; 4.times { GC.start }; GC.compact if GC.respond_to?(:compact); GC.verify_internal_consistency
report("kept hashes") { keep.each_with_index.all? { |h, i| h == { x: "young#{i}", y: [i] } } }
ObjectSpace.trace_object_allocations { h = dk(OBJS[:struct], [:x]); report("allocation tracing") { [ObjectSpace.allocation_method_id(h), ObjectSpace.allocation_class_path(h)] } }
