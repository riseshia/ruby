# Marshal round trips of Struct / Data (compare against master)
def show(*a) = puts(a.map(&:inspect).join(" "))
def rt(o, **kw) = Marshal.load(Marshal.dump(o), **kw)
S = Struct.new(:a, :b); K = Struct.new(:a, :b, keyword_init: true); D = Data.define(:a, :b)
class Sub < S; def initialize(*) = (super; @extra = 1); attr_reader :extra; end
show rt(S.new(1, "x")), rt(K.new(a: 1, b: "x")), rt(D.new(a: 1, b: "x")), rt(D.new(a: 1, b: "x")).frozen?
show rt(S.new(1, "x")).frozen?, rt(K.new(a: 1, b: "x")).frozen?
r = S.new(1, nil); r.b = r; l = rt(r); show l.b.equal?(l), l.a
o = S.new(1, 2); o.instance_variable_set(:@iv, :v); l = rt(o); show l, l.instance_variable_get(:@iv)
l = rt(Sub.new(1, 2)); show l.class, l.to_a, l.extra
show rt([S.new(1, 2), S.new(1, 2), D.new(a: 1, b: 2)]).map(&:class)
a = S.new(1, 2); show rt([a, a]).then { |x| x[0].equal?(x[1]) }
show rt(S.new(1, 2), freeze: true).frozen?, rt(S.new("s", 2), freeze: true).a.frozen?
seen = []; show rt(S.new(1, D.new(a: 2, b: 3))), Marshal.load(Marshal.dump(S.new(1, [2])), ->(x) { seen << x; x }), seen
# incompatible
S2 = Struct.new(:a, :b); dump = Marshal.dump(S2.new(1, 2)).sub("S2", "S3"); S3 = Struct.new(:a, :c)
begin; Marshal.load(dump); rescue => e; show e.class, e.message; end
S4 = Struct.new(:a); dump4 = Marshal.dump(S.new(1, 2)).sub(":\x06S", ":\aS4"); begin; Marshal.load(dump4); rescue => e; show e.class, e.message; end
# not a struct any more
dump5 = Marshal.dump(S.new(1, 2)).sub(":\x06S", ":\x06X"); X = Class.new; begin; Marshal.load(dump5); rescue => e; show e.class, e.message; end
# custom marshal_dump / _dump on a Struct
M = Struct.new(:a) { def marshal_dump = [a * 2]; def marshal_load(x) = self.a = x[0] }; show rt(M.new(21))
# Struct with initialize override: not called by load
I = Struct.new(:a) { def initialize(*) = (super; puts "init called") }; show rt(I.new(1))
# Data with initialize override
DI = Data.define(:a) { def initialize(a:) = (puts "dinit"; super(a: a * 2)) }; show rt(DI.new(a: 1))
# Data positional dump format compatibility: dumped strings equal on both
show Marshal.dump(S.new(1, 2)), Marshal.dump(K.new(a: 1, b: 2)), Marshal.dump(D.new(a: 1, b: 2))
# nil members and many members
W = Struct.new(*(:a..:z).to_a); show rt(W.new(*1..26)).to_a.sum, rt(W.new).to_a.compact
show rt(S.new(:sym, 1.5)), rt(S.new(nil, nil)), rt(K.new(a: nil))
# GC stress during load
GC.stress = true; show rt([S.new("a" * 10, [1, 2]), D.new(a: {x: 1}, b: "y")]); GC.stress = false
# load after members reordered (member name mismatch)
begin; Marshal.load(Marshal.dump(S.new(1, 2)).sub(":\x06a", ":\x06b").sub(":\x06b", ":\x06a")); rescue => e; show e.class, e.message; end
