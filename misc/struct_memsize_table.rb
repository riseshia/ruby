# Slot size of an instance by member count: plain class (ivars) vs Struct vs Data.
require "objspace"

def plain_class(n)
  Class.new {
    class_eval "def initialize(#{(1..n).map { "a#{_1}" }.join(", ")}); #{(1..n).map { "@a#{_1} = a#{_1}" }.join("; ")}; end"
  }
end

puts RUBY_DESCRIPTION
puts "slot sizes: #{GC.stat_heap.values.map { _1[:slot_size] }.inspect}"
puts format("%-8s %8s %8s %8s", "members", "class", "Struct", "Data")
(1..10).each do |n|
  args = (1..n).to_a
  members = (1..n).map { :"a#{_1}" }
  plain = plain_class(n)
  plain.new(*args) # let the class learn its ivar count
  sizes = [plain.new(*args), Struct.new(*members).new(*args), Data.define(*members).new(*args)].map { ObjectSpace.memsize_of(_1) }
  puts format("%-8d %8d %8d %8d", n, *sizes)
end
