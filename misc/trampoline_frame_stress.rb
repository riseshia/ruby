# The JIT-pushed frame of Data.new under conditions that discard or exit JIT code in the middle of things.
D = Data.define(:x, :y) { def initialize(x:, y: 0) = super(x:, y:) }
E = Data.define(:x) { def initialize(x:) = (raise ArgumentError, "neg" if x.is_a?(Integer) && x < 0; super(x: x.is_a?(String) ? x.dup : x)) }
def make(i) = D.new(x: i, y: [i])
def flaky(v) = E.new(x: v)
def chain(i) = D.new(x: D.new(x: i), y: E.new(x: i))
bad = 0
20_000.times do |i|
  o = make(i); bad += 1 unless o.x == i && o.y == [i] && o.frozen?
  v = [i, "s#{i}", :sym, nil, 1.5][i % 5]          # type changes force side exits inside initialize
  e = (flaky(i % 97 == 0 ? -1 : v) rescue :raised); bad += 1 unless e == :raised || e.x == v
  c = chain(i); bad += 1 unless c.x.x == i && c.y.x == i
  GC.start(full_mark: false) if i % 5000 == 0
end
puts "mixed: bad=#{bad}"
# invalidation while a frame pushed by JIT code is live: a constant is redefined from inside initialize
LIMIT = 1
F = Data.define(:x) { def initialize(x:) = (Object.send(:remove_const, :LIMIT); Object.const_set(:LIMIT, x); super(x: x + LIMIT)) }
def inval(i) = F.new(x: i)
ok = 3000.times.all? { |i| inval(i).x == i * 2 }
puts "constant redefined inside initialize: #{ok}"
# method redefined from inside initialize, then again
G = Data.define(:x) { def initialize(x:) = (G.class_eval { def helper = :v2 } if x == 1500; super(x: [x, helper])); def helper = :v1 }
def redef(i) = G.new(x: i)
r = 3000.times.map { |i| redef(i).x[1] }.tally
puts "method redefined inside initialize: #{r}"
# TracePoint enabled from inside initialize (JIT code gets invalidated, the landing exits)
$events = []
H = Data.define(:x) { def initialize(x:) = (($tp = TracePoint.new(:c_return) { |tp| $events << tp.method_id if tp.method_id == :new }).enable if x == 2000; super) }
def traced(i) = H.new(x: i)
2100.times { |i| traced(i) }
$tp.disable
puts "c_return for new seen after enabling inside initialize: #{$events.size}"
# initialize defined later / removed
L = Data.define(:x)
def late(i) = L.new(x: i)
3000.times { late(_1) }
L.class_eval { def initialize(x:) = super(x: x + 1) }
a = late(1).x; 3000.times { late(_1) }
L.class_eval { remove_method :initialize }
puts "initialize added then removed: #{[a, late(1).x]}"
# deep recursion through new until SystemStackError
R = Data.define(:x) { def initialize(x:) = super(x: R.new(x: x + 1)) }
depth = begin; R.new(x: 0); rescue SystemStackError => e; e.class; end
puts "stack overflow through nested new: #{depth}"
puts "after overflow: #{make(1).to_h}"
GC.compact if GC.respond_to?(:compact)
GC.verify_internal_consistency
puts "heap consistent"
