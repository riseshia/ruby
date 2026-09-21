# Hot call sites whose receiver is a class a JIT cannot ask anything of while it compiles:
# Class.allocate has no superclass, and asking for one raises.
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
def attempt = yield.inspect rescue "#{$!.class}: #{$!.message.gsub(/0x\h+/, "0x")}"
def new0 = attempt { Class.allocate.new }
def new2 = attempt { Class.allocate.new(1, 2) }
def newkw = attempt { Class.allocate.new(x: 1) }
def aref = attempt { Class.allocate[1, 2] }
def members = attempt { Class.allocate.members }
def superclass = attempt { Class.allocate.superclass }
def struct_like(k) = attempt { k.new(1, 2) }
def data_like(k) = attempt { k.new(x: 1, y: 2) }
S = Struct.new(:a, :b); D = Data.define(:x, :y)
60.times { new0; new2; newkw; aref; members; superclass; struct_like(S); data_like(D) }
report("Class.allocate") { [new0, new2, newkw, aref, members, superclass] }
report("a Struct class, then an uninitialized one, at the same site") { [struct_like(S), struct_like(Class.allocate), struct_like(S), struct_like(Class.new), struct_like(Struct)] }
report("a Data class, then others, at the same site") { [data_like(D), data_like(Class.allocate), data_like(D), data_like(Data), data_like(Class.new(D))] }
report("instances still fine") { [S.new(1, 2).to_h, S.new(1).members, D.new(1, 2).to_h, D.new(x: 1, y: 2).members, S[3, 4]] }
