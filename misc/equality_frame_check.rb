# Struct#== / eql? called without a frame by a JIT: the frame must be there whenever it can be seen.
class Raises; def ==(o) = raise("boom in =="); def eql?(o) = raise("boom in eql?"); def hash = 0; end
class Peeks; def ==(o) = ($seen = caller_locations(0, 4).map(&:label); true); alias eql? ==; def hash = 0; end
class Recorder; def ==(o) = ($mid = __method__; $frames = caller.size; true); end
S = Struct.new(:a, :b); D = Data.define(:a, :b)
def eq(x, y) = x == y
def eql(x, y) = x.eql?(y)
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message} #{$!.backtrace_locations.first(4).map(&:label).inspect}")
pairs = { "ints" => [S.new(1, 2), S.new(1, 2)], "differ" => [S.new(1, 2), S.new(1, 3)], "data" => [D.new(1, :s), D.new(1, :s)], "data differ" => [D.new(1, :s), D.new(1, :t)],
          "other class" => [S.new(1, 2), D.new(1, 2)], "not a struct" => [S.new(1, 2), 5], "nested" => [S.new(S.new(1, 2), [3]), S.new(S.new(1, 2), [3])], "floats" => [D.new(1.0, 2), D.new(1, 2)] }
3.times { pairs.each_value { |x, y| 500.times { eq(x, y); eql(x, y) } } }
pairs.each { |label, (x, y)| report(label) { [eq(x, y), eql(x, y), eq(y, x)] } }
3.times do
  report("raises in ==") { eq(S.new(1, Raises.new), S.new(1, Raises.new)) }
  report("raises in eql?") { eql(D.new(1, Raises.new), D.new(1, Raises.new)) }
  report("caller seen from a member") { eq(S.new(1, Peeks.new), S.new(1, Peeks.new)); $seen }
  report("caller seen from a member, eql?") { eql(D.new(1, Peeks.new), D.new(1, Peeks.new)); $seen }
end
r1 = S.new(1, nil); r1.b = r1; r2 = S.new(1, nil); r2.b = r2
1000.times { eq(r1, r2); eql(r1, r2) }
report("recursive") { [eq(r1, r2), eql(r1, r2), eq(r1, S.new(1, r1))] }
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] if %i[== eql?].include?(tp.method_id) }.enable { eq(S.new(1, 2), S.new(1, 2)); eql(D.new(1, 2), D.new(1, 2)) }
report("traced") { events }
report("after tracing") { [eq(S.new(1, 2), S.new(1, 2)), eql(D.new(1, 2), D.new(1, 3))] }
S.class_eval { def ==(o) = :redefined }
report("redefined") { eq(S.new(1, 2), S.new(1, 2)) }
