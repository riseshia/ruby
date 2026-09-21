# -*- coding: utf-8 -*-
# Struct#inspect / Data#inspect: text, encoding and the calls it makes must not depend on
# how the members are turned into text.
S = Struct.new(:x, :y, :z); D = Data.define(:x, :y)
Jp = Struct.new(:"名前", :x)
Odd = Struct.new(:"foo bar", :"a?", :B, :"9x")
class StrSub < String; def inspect = "SUB(#{super})"; end
singleton = +"single"; def singleton.inspect = "SINGLETON"
binary = "\xff\xfe".b; sjis = "\x82\xa0".dup.force_encoding("Shift_JIS"); utf16 = "ab".encode("UTF-16LE")
broken = "\xff".dup.force_encoding("UTF-8")
rec = S.new(1, 2, nil); rec.z = rec
nested = S.new(S.new(1, "a", nil), [S.new(nil, true, false)], {k: D.new(1, 2)})

def show(label, obj)
  text = obj.inspect
  puts "#{label}: #{text.b} | #{text.encoding} | ascii_only=#{text.ascii_only?} valid=#{text.valid_encoding?} frozen=#{text.frozen?} to_s_same=#{obj.to_s == text}"
rescue => e
  puts "#{label}: #{e.class}: #{e.message}"
end

values = {
  "ints" => S.new(0, -1, 2**62 - 1), "fixnum edge" => S.new(-(2**62), 2**62, 2**64), "nil true false" => S.new(nil, true, false),
  "strings" => S.new("a", "quote\"s\n", "日本語"), "binary" => S.new(binary, 1, nil), "sjis" => S.new(sjis, 1, nil),
  "utf16" => S.new(utf16, 1, nil), "broken" => S.new(broken, 1, nil), "string subclass" => S.new(StrSub.new("s"), 1, nil),
  "singleton string" => S.new(singleton, 1, nil), "frozen literal" => S.new("lit".freeze, :sym, 1.5),
  "mixed" => S.new(1, [2], {a: 3}), "data" => D.new(1, "two"), "data symbols" => D.new(:a, nil),
  "anonymous" => Struct.new(:a).new(1), "anonymous data" => Data.define(:a).new("x"), "empty" => Struct.new("EmptyProbe").new,
  "non-ascii member" => Jp.new("n", 1), "odd members" => Odd.new(1, "2", nil, true), "recursive" => rec, "nested" => nested,
  "symbols" => S.new(:a, :"foo bar", :"9x"), "non-ascii symbol" => S.new(:"名前", "\x82\xa0".dup.force_encoding("Shift_JIS").to_sym, :"quote\"d"),
  "floats" => S.new(1.5, -0.0, 1e100), "special floats" => S.new(Float::NAN, Float::INFINITY, 2.0**70), "bignum" => S.new(2**64, -(2**80), 10**30),
  "keyword_init" => Struct.new(:a, keyword_init: true).new(a: 1),
}
values.each { |label, obj| show(label, obj) }

[["UTF-8", nil], ["Shift_JIS", nil], ["UTF-8", "EUC-JP"], ["US-ASCII", nil], ["UTF-16LE", nil]].each do |ext, int|
  begin
    verbose, $VERBOSE = $VERBOSE, nil
    Encoding.default_external = ext; Encoding.default_internal = int
  ensure
    $VERBOSE = verbose
  end
  puts "-- default_external=#{ext} default_internal=#{int.inspect}"
  ["ints", "strings", "binary", "sjis", "non-ascii member", "data", "symbols", "non-ascii symbol", "floats", "bignum"].each { |label| show(label, values.fetch(label)) }
rescue => e
  puts "-- #{ext}/#{int.inspect}: #{e.class}: #{e.message}"
end
begin
  verbose, $VERBOSE = $VERBOSE, nil
  Encoding.default_external = "UTF-8"; Encoding.default_internal = nil
ensure
  $VERBOSE = verbose
end

events = []
TracePoint.new(:c_call) { |tp| events << tp.method_id if tp.method_id == :inspect || tp.method_id == :to_s }.enable { S.new(1, "a", nil).inspect }
puts "c_call while traced: #{events.inspect}"
show("after tracing", S.new(1, "a", nil))

3.times { S.new(12, "s", nil).inspect }
class Integer; alias_method :__inspect, :inspect; def inspect = "INT(#{__inspect})"; end
show("Integer#inspect redefined", S.new(12, "s", nil))
class Integer; alias_method :inspect, :__inspect; end
class String; alias_method :__inspect, :inspect; def inspect = "STR"; end
show("String#inspect redefined", S.new(12, "s", nil))
class String; alias_method :inspect, :__inspect; end
class Symbol; alias_method :__inspect, :inspect; def inspect = "SYM"; end
show("Symbol#inspect redefined", S.new(:a, 1.5, 2**64))
class Symbol; alias_method :inspect, :__inspect; end
class Float; def inspect = "FLO"; end
show("Float#inspect redefined", S.new(:a, 1.5, 2**64))
class Float; remove_method :inspect; end
show("Float#inspect restored", S.new(:a, 1.5, 2**64))
class Integer; def to_s(*) = "TO_S"; end
show("Integer#to_s redefined (inspect is an alias entry of its own)", S.new(12, 1.5, 2**64))
class Integer; remove_method :to_s; end
class NilClass; def inspect = "NIL"; end
show("NilClass#inspect redefined", S.new(12, "s", nil))
class NilClass; def inspect = "nil"; end
module Shout; def inspect = super.upcase; end
String.prepend(Shout)
show("String prepended", S.new(12, "s", nil))
hidden = S.new(1, 2, nil); holder = Object.new; holder.define_singleton_method(:inspect) { hidden.inspect }
hidden.z = holder
show("recursion through another object's inspect", hidden)
