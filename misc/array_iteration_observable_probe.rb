# Prints what a Ruby program can observe about Array#each_index and Array#reject.
# Run it with a baseline and a patched build under the same JIT option: outputs must be identical.

def section(title) = puts("\n== #{title}")

def report(label)
  value = yield
  puts "  #{label}: #{value.inspect}"
rescue => error
  puts "  #{label}: #{error.class}: #{error.message}"
  puts "    backtrace labels: #{error.backtrace_locations.first(4).map(&:label).inspect}"
  puts "    backtrace lines: #{error.backtrace_locations.first(3).map { "#{File.basename(_1.path)}:#{_1.lineno > 0 ? "n" : 0}" }.inspect}"
end

def trace_events(label)
  events = []
  tracer = TracePoint.new(:c_call, :c_return, :call, :return, :b_call) { |tp| events << "#{tp.event} #{tp.defined_class.inspect}##{tp.method_id}" }
  tracer.enable { yield }
  puts "  #{label}:"
  events.each { puts "    #{_1}" }
end

class SubArray < Array; end

%i[each_index reject].each do |name|
  section "Array##{name}"
  meth = [].method(name)
  report("owner / arity / parameters") { [meth.owner, meth.arity, meth.parameters] }
  report("source_location") { meth.source_location }
  report("without a block") { e = [1, 2, 3].public_send(name); [e.class, e.size, e.next] }
  report("result") { [1, 2, 3, 4].public_send(name) { |x| x.even? } }
  report("result on empty / frozen") { [[].public_send(name) { true }, [1, 2].freeze.public_send(name) { |x| x == 1 }] }
  report("result class on a subclass") { SubArray[1, 2, 3].public_send(name) { |x| x == 1 }.class }
  report("array grows while iterating") { a = [1, 2]; seen = []; a.public_send(name) { |x| seen << x; a << 9 if a.size < 5; false }; [seen, a] }
  report("array shrinks while iterating") { a = [1, 2, 3, 4]; seen = []; a.public_send(name) { |x| seen << x; a.pop; false }; [seen, a] }
  report("break / next") { [[1, 2, 3].public_send(name) { |x| break :stopped if x == 1 }, [1, 2, 3].public_send(name) { |x| next true }] }
  report("block raising") { [1, 2].public_send(name) { raise ArgumentError, "inside" } }
  report("caller inside the block") { labels = nil; [1].public_send(name) { labels = caller_locations(0, 3).map(&:label) }; labels }
  report("block arity and lambda") { [[[1, 2]].public_send(name) { |a, b| [a, b] == [0, nil] }, [1].public_send(name, &->(x) { x })] }
  trace_events("traced") { [1, 2].public_send(name) { |x| x } }
end

section "redefinition"
class Array
  alias_method :__probe_each_index, :each_index
  def each_index(&) = (puts "    Array#each_index redefined"; __probe_each_index(&))
end
report("after redefinition") { [1, 2].each_index.to_a }
