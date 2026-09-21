# Struct#inspect / Data#inspect around the size of the byte buffer it collects text in,
# and wherever text that is not plain ASCII bytes comes in between.
require "digest" rescue nil
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
def describe(str) = [str.bytesize, str.encoding.to_s, str.valid_encoding?, str.ascii_only?, str.frozen?, str.hash == str.dup.force_encoding(str.encoding).hash, str.sum, str[0, 40], str[-40, 40]]
(1..60).each do |n|
  k = Struct.new(*Array.new(n) { :"member_name_#{_1}" })
  d = Data.define(*Array.new(n) { :"member_name_#{_1}" })
  vals = Array.new(n) { |i| [i, -i * 10**12, nil, true, false, :"sym#{i}", i * 1.5, "s" * i, 2**70 + i][i % 9] }
  report("struct #{n}") { describe(k.new(*vals).inspect) }
  report("data #{n}") { describe(d.new(*vals).inspect) }
end
[1, 100, 150, 158, 159, 160, 161, 162, 200, 319, 320, 321, 1000].each do |len|
  long = Struct.new(:"#{'n' * len}", :b)
  report("name of #{len}") { describe(long.new(1, 2).inspect) }
  report("string of #{len}") { describe(Struct.new(:a, :b).new("x" * len, -5).inspect) }
  report("symbol of #{len}") { describe(Data.define(:a, :b).new(:"#{'y' * len}", 7).inspect) }
end
Named = Struct.new(:a, :b); NamedData = Data.define(:a, :b); ÜberStruct = Struct.new(:größe, :b)
report("non-ASCII member between ASCII ones") { [Struct.new(:a, :"é", :c, :"日本", :e).new(1, 2, 3, 4, 5), ÜberStruct.new(1, 2)].map { describe(_1.inspect) } }
report("non-ASCII values") { [Named.new("é", 1), Named.new(1, "日本"), Named.new(:"é", nil), Named.new("\xff".b, 2), Named.new("a".encode("UTF-16LE"), 3), NamedData.new("é".encode("ISO-8859-1"), :z)].map { describe(_1.inspect) } }
report("operator and odd member names") { [Struct.new(:"a?", :b).new(1, 2), Struct.new(:"a b", :"1x", :A).new(1, 2, 3), Struct.new(:"@iv", :"$g").new(1, 2)].map(&:inspect) }
report("members that are not leaves") { [Named.new([1, 2], { k: Named.new(1, 2) }), Named.new(Object.new.then { |o| def o.inspect = "custom"; o }, 1), NamedData.new(NamedData.new(1, 2), [nil])].map(&:inspect) }
rec = Named.new(1, nil); rec.b = rec
report("recursive") { [rec.inspect, Named.new(rec, 2).inspect] }
class Integer; alias_method :orig_inspect, :inspect; def inspect = "int(#{orig_inspect})"; end
report("Integer#inspect redefined") { [Named.new(1, -2).inspect, NamedData.new(3, nil).inspect] }
class Integer; alias_method :inspect, :orig_inspect; end
report("restored") { Named.new(1, -2).inspect }
report("default_internal") { Encoding.default_internal = "UTF-8"; r = describe(Named.new(1, :b).inspect); Encoding.default_internal = nil; r }
report("default_external binary") { old = Encoding.default_external; Encoding.default_external = "ASCII-8BIT"; r = describe(Named.new(1, "é").inspect); Encoding.default_external = old; r }
