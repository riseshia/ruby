# The count of active recursion guards must return to zero whatever happens inside a guarded call:
# exceptions, throw, fibers switched in the middle, threads, a TracePoint hook. Observed through
# behaviour only: after each scenario a plain comparison of different structs must answer false and
# recursive structures must still be detected.
S = Struct.new(:a, :b)
class Boom; def ==(o) = raise("boom"); def inspect = raise("boom"); def hash = raise("boom"); end
class Thrower; def ==(o) = throw(:out, :thrown); def inspect = throw(:out, :thrown); end
class Yielder; def initialize(f) = @f = f; def ==(o) = (Fiber.yield(:inside); true); def inspect = (Fiber.yield(:inside); "Y"); end
def probe
  r = S.new(1, nil); r.b = r
  [S.new(1, 2) == S.new(1, 3), S.new(1, 2).eql?(S.new(1, 3)), S.new(1, [2]) == S.new(1, [3]), r == r.dup, r.inspect, [r].hash == [r].hash, {S.new(1, 2) => 1}[S.new(1, 3)]]
end
results = { "baseline" => probe }
(S.new(1, Boom.new) == S.new(1, Boom.new)) rescue nil; (S.new(1, Boom.new).inspect) rescue nil; ([S.new(1, Boom.new)].hash) rescue nil
results["after exceptions"] = probe
catch(:out) { S.new(1, Thrower.new) == S.new(1, Thrower.new) }; catch(:out) { [S.new(1, Thrower.new)].inspect }
results["after throw"] = probe
f = Fiber.new { S.new(1, Yielder.new(nil)) == S.new(1, Yielder.new(nil)); [Yielder.new(nil)].inspect; :done }
results["fiber suspended inside =="] = [f.resume, probe]
results["fiber suspended inside inspect"] = [f.resume, probe]
results["fiber finished"] = [f.resume, probe]
abandoned = Fiber.new { S.new(1, Yielder.new(nil)) == S.new(1, Yielder.new(nil)) }; abandoned.resume
results["fiber abandoned inside =="] = probe
results["other thread"] = Thread.new { (S.new(1, Boom.new) == S.new(1, Boom.new)) rescue nil; probe }.value
events = 0
TracePoint.new(:c_call) { |tp| events += 1; [S.new(1, [2])].inspect; S.new(1, [2]) == S.new(1, [3]) }.enable { S.new(1, [2]) == S.new(1, [2]); [S.new(1, 2)].inspect }
results["after a TracePoint hook that compares"] = [events > 0, probe]
Thread.current[:__recursive_key__] = nil
results["after the guard table is reset from Ruby"] = probe
base = results["baseline"]
results.each { |label, r| puts "#{label}: #{r.flatten.last(7) == base ? 'consistent' : 'DIFFERENT'} #{r.inspect[0, 120]}" }
