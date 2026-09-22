# Struct#each / #each_pair observable behaviour (compare against master in every mode)
S = Struct.new(:a, :b, :c)
s = S.new(1, 2, 3)
def show(*a) = puts(a.map(&:inspect).join(" "))
r = []; show s.each { |v| r << v }.equal?(s), r
r = []; show s.each_pair { |k, v| r << [k, v] }.equal?(s), r
r = []; s.each_pair { |pair| r << pair }; show r
r = []; s.each_pair { |k, v = :none| r << [k, v] }; show r
r = []; s.each_pair(&lambda { |pair| r << pair }); show r
begin; r = []; s.each_pair(&->(k, v) { r << [k, v] }); show r; rescue ArgumentError => e; show e.class, e.message; end
r = []; s.each_pair { |*a| r << a }; show r
r = []; s.each { |a, b| r << [a, b] }; show r
show s.each.class, s.each.size, s.each_pair.size, s.each.to_a, s.each_pair.to_a
show s.each_with_index.to_a, s.each_pair.with_index.to_a
show S.instance_method(:each).arity, S.instance_method(:each).source_location, S.instance_method(:each).owner
show S.instance_method(:each_pair).arity, S.instance_method(:each_pair).source_location, S.instance_method(:each_pair).parameters
begin; s.each { |v| raise "boom #{v}" }; rescue => e; show e.message, e.backtrace; end
begin; s.each_pair { |k, v| raise "boom #{k}" }; rescue => e; show e.message, e.backtrace; end
s.each { |v| show caller_locations(0).map(&:to_s); break }
ev = []; TracePoint.new(:call, :c_call, :return, :c_return, :b_call, :b_return, :line) { |t| ev << [t.event, t.method_id, t.path, t.lineno] }.enable { s.each { |v| v }; s.each_pair { |k, v| v } }; show ev
# mutation during iteration
r = []; s.each { |v| s.b = 20 if v == 1; r << v }; show r, s.to_a
# break / next / return values
show s.each { |v| break v * 10 if v == 2 }
def f(s) = s.each { |v| return v if v == 3 }; show f(s)
show s.each { |v| next 5 }
# size mismatch after each (corrupted struct guard): subclass with extra members
class Sub < S; end; show Sub.new(1, 2, 3).each_pair.to_a
# uninitialized
begin; Struct.allocate.each { }; rescue => e; show e.class, e.message; end
# each with no block from Enumerator size when struct frozen
show s.freeze.each.size
# each_pair with unusual block: method proc
def m2(k, v) = [k, v]; r = []; s.each_pair(&method(:m2).to_proc); show r
r = []; s.each_pair(&:inspect); show r
show s.each_pair.map { |k, v| [k, v] }, s.each_pair.map { |pair| pair }
show S.new(1, 2, 3).each_pair.to_a.frozen?
# Data has no each
show Data.define(:x).new(x: 1).respond_to?(:each)
# each on struct with singleton and refined
show s.respond_to?(:each), Struct.instance_methods(false).sort
show S.public_instance_method(:each).inspect.sub(/0x\h+/, "X")
