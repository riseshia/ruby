# `super` from an overriding method into the reader / writer that Struct.new and Data.define generate.
Base = Struct.new(:x, :y); Big = Struct.new(*(1..100).map { :"m#{_1}" })
class Defaulted < Base; def x = super || :default; def y=(v); super(v.to_s); end; end
class BigSub < Big; def m100 = super; def m100=(v); super; end; end
class Coord < Data.define(:lat, :lng); def lat = super.round(1); end
module Loud; def x = super.to_s.upcase; def x=(v); super(v * 2); end; end
class Shared1 < Struct.new(:x, :a); include Loud; end
class Shared2 < Struct.new(:a, :b, :x); include Loud; end     # same method, x at another position
class WithArgs < Base; def x(*args) = super; def y = super(); end
class Blocky < Base; def x(&blk) = super; def y = super { 1 }; end
class Frozen < Base; def x=(v); super; end; end
class Kw < Base; def x(k: 1) = super(); end

CASES = {
  "default" => -> { [Defaulted.new(nil, 1).x, Defaulted.new(5, 1).x] },
  "writer" => -> { d = Defaulted.new(1, 2); r = (d.y = 42); [d.y, r] },
  "100th member (not embedded)" => -> { b = BigSub.new(*1..100); b.m100 = :z; [b.m100, b.m99] },
  "data" => -> { Coord.new(1.2345, 2).lat },
  "one method, two layouts" => -> { a = Shared1.new("a", 1); b = Shared2.new(1, 2, "b"); a.x = "q"; b.x = "w"; [a.x, b.x, a.to_a, b.to_a] },
  "zsuper with rest args" => -> { [WithArgs.new(1, 2).x, (WithArgs.new(1, 2).x(1) rescue $!.message), WithArgs.new(1, 2).y] },
  "block passed on" => -> { [Blocky.new(1, 2).x { 0 }, Blocky.new(1, 2).y] },
  "frozen receiver" => -> { Frozen.new(1, 2).freeze.x = 3 },
  "keyword parameter, explicit empty super" => -> { Kw.new(1, 2).x(k: 2) },
  "singleton override" => -> { o = Base.new(1, 2); def o.x = super + 100; o.x },
  "young value through old struct" => -> { d = Defaulted.new(1, 2); 3.times { GC.start }; d.y = [1, [2]]; GC.start(full_mark: false); d.y },
}
CASES.each do |label, body|
  result = nil
  500.times do
    result = begin
      body.call.inspect
    rescue => error
      "#{error.class}: #{error.message} #{error.backtrace_locations.first(2).map(&:label).inspect}"
    end
  end
  puts "#{label}: #{result}"
end
events = []
TracePoint.new(:c_call, :c_return) { |tp| events << [tp.event, tp.method_id] }.enable { Defaulted.new(1, 2).x }
puts "events: #{events.inspect}"
hot = Defaulted.new(1, 2); 3000.times { hot.x }
Base.class_eval { def x = :redefined }
puts "after the reader is redefined: #{hot.x.inspect}"
