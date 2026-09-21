# The usual ways of overriding initialize, from hot call sites, with good and bad arguments.
def report(label) = puts("#{label}: #{(yield).inspect.gsub(/0x\h+/, '0x')}") rescue puts("#{label}: #{$!.class}: #{$!.message.gsub(/0x\h+/, '0x')}")
def attempt = yield rescue "#{$!.class}: #{$!.message}"
SRest = Struct.new(:x, :y) { def initialize(*args) = super }
SRestExplicit = Struct.new(:x, :y) { def initialize(*args) = super(*args) }
SRestMore = Struct.new(:x, :y) { def initialize(*args) = super(*args, :extra) }
SOpt = Struct.new(:x, :y) { def initialize(x, y = 0) = super }
SKwrest = Struct.new(:x, :y, keyword_init: true) { def initialize(**kw) = super }
SKwrestExplicit = Struct.new(:x, :y, keyword_init: true) { def initialize(**kw) = super(**kw) }
SKwKept = Struct.new(:x, :y, keyword_init: true) { def initialize(**kw) = ($kept = kw; super) }
DKwrest = Data.define(:x, :y) { def initialize(**kw) = super }
DKwrestExplicit = Data.define(:x, :y) { def initialize(**kw) = super(**kw) }
DKwMerge = Data.define(:x, :y) { def initialize(**kw) = super(y: 0, **kw) }
DKwKept = Data.define(:x, :y) { def initialize(**kw) = ($kept = kw; super(**kw)) }
DKwMutate = Data.define(:x, :y) { def initialize(**kw) = (super(**kw); $after = kw.frozen?; kw[:z] = 1; $kept = kw) }
DTwice = Data.define(:x, :y) { def initialize(**kw) = (super(**kw); (super(**kw) rescue $twice = $!.class)) }
DHashArg = Data.define(:x, :y) { def initialize(h = nil, **kw) = super(**(h || kw)) }
KLASSES = [SRest, SRestExplicit, SRestMore, SOpt, SKwrest, SKwrestExplicit, SKwKept, DKwrest, DKwrestExplicit, DKwMerge, DKwKept, DKwMutate, DTwice, DHashArg]
KLASSES.each { |k| eval "def pos_#{k.name}(a, b) = #{k.name}.new(a, b); def one_#{k.name}(a) = #{k.name}.new(a); def kw_#{k.name}(a, b) = #{k.name}.new(x: a, y: b); def kwx_#{k.name}(a) = #{k.name}.new(x: a); def bad_#{k.name}(a) = #{k.name}.new(x: a, nope: 1); def splat_#{k.name}(h) = #{k.name}.new(**h)" }
300.times { KLASSES.each { |k| %w[pos one kw kwx].each { |m| send("#{m}_#{k.name}", *[1, 2].first(m == "one" || m == "kwx" ? 1 : 2)) rescue nil }; splat_h = { x: 1, y: 2 }; send("splat_#{k.name}", splat_h) rescue nil } }
KLASSES.each do |k|
  h = { x: "a", y: "b" }
  report(k.name) { [attempt { send("pos_#{k.name}", 1, 2) }, attempt { send("one_#{k.name}", 1) }, attempt { send("kw_#{k.name}", 1, 2) }, attempt { send("kwx_#{k.name}", 1) }, attempt { send("bad_#{k.name}", 1) }, attempt { send("splat_#{k.name}", h) }, h, attempt { send("kw_#{k.name}", 1, 2).frozen? }] }
end
report("the Hash initialize kept") { kw_DKwKept(1, 2); a = $kept; kw_SKwKept(3, 4); [a, a.frozen?, $kept, $kept.frozen?] }
report("the Hash after super") { o = kw_DKwMutate(1, 2); [o, $after, $kept] }
report("initialize twice") { o = kw_DTwice(1, 2); [o, $twice] }
report("values shared, not copied") { v = "str"; [kw_DKwrest(v, v).x.equal?(v), kw_SKwrest(v, v).y.equal?(v)] }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { kw_DKwrest(1, 2); kw_SKwrest(1, 2); pos_SRest(1, 2) }
report("traced") { events }
300.times { kw_DKwrest(1, 2); kw_SKwrest(1, 2); pos_SRest(1, 2) }
GC.stress = true; ok = 20.times.all? { |i| kw_DKwrest([i], "s#{i}").x == [i] && kw_SKwrest("s#{i}", [i]).y == [i] && pos_SRest([i], i).x == [i] && kw_DKwMerge(i, [i]).y == [i] }; GC.stress = false
report("gc stress") { ok }
class DKwrest; def initialize(**kw) = super(**kw.transform_values(&:to_s)); end
report("initialize redefined") { kw_DKwrest(1, 2) }
