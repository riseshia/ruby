# Prints what a Ruby program can observe about Kernel#dup.
# Run it with a baseline and a patched build: the two outputs must be identical.

def section(title) = puts("\n== #{title}")

def report(label)
  value = yield
  puts "  #{label}: #{value.inspect}"
rescue => error
  puts "  #{label}: #{error.class}: #{error.message}"
  puts "    backtrace labels: #{error.backtrace_locations.first(4).map(&:label).inspect}"
end

def trace_events(label)
  events = []
  tracer = TracePoint.new(:c_call, :c_return, :call, :return) { |tp| events << "#{tp.event} #{tp.defined_class.inspect}##{tp.method_id}" }
  tracer.enable { yield }
  puts "  #{label}:"
  events.each { puts "    #{_1}" }
end

class Plain
  attr_accessor :a, :b
  def initialize(a, b) = (@a = a; @b = b)
end

class WithCopyHook < Plain
  def initialize_copy(orig) = (puts "    WithCopyHook#initialize_copy from #{orig.a}"; super; @a = :copied)
end

class WithDupHook < Plain
  def initialize_dup(orig) = (puts "    WithDupHook#initialize_dup"; super)
end

class RaisingCopy < Plain
  def initialize_copy(orig) = raise(ArgumentError, "no copies")
end

class TrackedArray < Array
  def initialize_copy(orig) = (puts "    TrackedArray#initialize_copy"; super)
end

class PlainArray < Array; end

section "plain objects"
report("dup copies ivars") { o = Plain.new(1, [2]); d = o.dup; [d.a, d.b.equal?(o.b), d.equal?(o), d.class] }
report("dup of frozen is not frozen, clone is") { o = Plain.new(1, 2).freeze; [o.dup.frozen?, o.clone.frozen?, o.clone(freeze: false).frozen?] }
report("singleton methods are not copied by dup") { o = Plain.new(1, 2); def o.extra = 1; [o.dup.respond_to?(:extra), o.clone.respond_to?(:extra)] }
report("initialize_copy hook") { WithCopyHook.new(1, 2).dup.a }
report("initialize_dup hook") { WithDupHook.new(1, 2).dup.a }
report("initialize_copy raising") { RaisingCopy.new(1, 2).dup }
report("hook added after the first dup") do
  klass = Class.new(Plain)
  first = klass.new(1, 2).dup.a
  klass.class_eval { def initialize_copy(orig) = (super; @a = :late) }
  [first, klass.new(1, 2).dup.a]
end
report("hook from an included module") do
  mod = Module.new { def initialize_copy(orig) = (super; @a = :from_module) }
  klass = Class.new(Plain) { include mod }
  klass.new(1, 2).dup.a
end
report("special objects") { [1.dup, :s.dup, nil.dup, true.dup, 1.5.dup, (2**70).dup == 2**70] }
report("method owners") { [Plain.instance_method(:dup).owner, Array.instance_method(:dup).owner, Hash.instance_method(:dup).owner, Plain.new(1, 2).method(:initialize_copy).owner] }

section "Array"
report("dup") { a = [1, [2], "s"]; d = a.dup; [d, d.equal?(a), d[1].equal?(a[1]), d.frozen?] }
report("dup of frozen / empty / large") { [[1].freeze.dup.frozen?, [].dup, Array.new(5000) { _1 }.dup.size] }
report("dup then mutate leaves the original alone") { a = Array.new(100) { _1 }; d = a.dup; d << :x; d[0] = :y; [a.size, a[0], d.size] }
report("ivar on an array") { a = [1]; a.instance_variable_set(:@tag, :t); a.dup.instance_variable_get(:@tag) }
report("subclass keeps its class") { [PlainArray[1, 2].dup.class, PlainArray[1, 2].dup] }
report("subclass with initialize_copy") { TrackedArray[1, 2].dup }

section "Hash"
report("dup") { h = {a: [1]}; d = h.dup; [d, d.equal?(h), d[:a].equal?(h[:a]), d.frozen?] }
report("default, default_proc, compare_by_identity") do
  with_default = Hash.new(5).dup
  with_proc = Hash.new { |hash, key| key * 2 }.dup
  by_identity = {}.compare_by_identity.dup
  [with_default[:missing], with_proc[4], by_identity.compare_by_identity?]
end
report("large hash") { h = (1..100).to_h { [_1, _1] }; d = h.dup; d[:x] = 1; [h.size, d.size] }
report("dup while iterating") { h = {a: 1, b: 2}; h.each { h.dup[:c] = 3 }; h }
report("ENV.dup") { ENV.dup }

section "hooks redefined on core classes"
trace_events("Plain#dup traced") { Plain.new(1, 2).dup }
trace_events("Array#dup traced") { [1].dup }
trace_events("Hash#dup traced") { {a: 1}.dup }

class Array
  alias_method :__probe_initialize_copy, :initialize_copy
  def initialize_copy(orig) = (puts "    Array#initialize_copy redefined"; __probe_initialize_copy(orig))
end
report("after Array#initialize_copy is redefined") { [1, 2].dup }

module Kernel
  alias_method :__probe_initialize_dup, :initialize_dup
  def initialize_dup(orig) = (puts "    Kernel#initialize_dup redefined"; __probe_initialize_dup(orig))
end
report("after Kernel#initialize_dup is redefined") { [Plain.new(1, 2).dup.a, {a: 1}.dup] }
