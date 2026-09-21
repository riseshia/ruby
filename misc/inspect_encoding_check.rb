# Struct#inspect under every combination of default external / internal encodings,
# with members whose inspect text is not ASCII.
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
def describe(str) = [str.encoding.to_s, str.valid_encoding?, str.bytes.sum, str.bytesize]
S = Struct.new(:a, :b); D = Data.define(:a, :b); Inner = Struct.new(:v)
VALUES = { "utf8" => "é日本", "eucjp" => "日本".encode("EUC-JP"), "sjis" => "日本".encode("Windows-31J"), "latin1" => "é".encode("ISO-8859-1"), "binary" => "\xff\xfe".b,
           "utf16" => "é".encode("UTF-16LE"), "ascii" => "abc", "sym utf8" => :"é", "sym eucjp" => "日本".encode("EUC-JP").to_sym, "broken" => "\xE3\x81".dup.force_encoding("UTF-8") }
def hot(o) = o.inspect
300.times { hot(S.new(1, "x")); hot(D.new(:a, nil)); hot(S.new(Inner.new("x"), 1)) }
[[nil, nil], ["UTF-8", nil], ["EUC-JP", nil], ["EUC-JP", "UTF-8"], ["UTF-8", "EUC-JP"], ["ASCII-8BIT", nil], ["US-ASCII", nil], ["Windows-31J", "UTF-8"], ["UTF-8", "UTF-8"], ["ISO-8859-1", nil], ["UTF-16LE", nil]].each do |ext, int|
  old_ext, old_int = Encoding.default_external, Encoding.default_internal
  begin
    Encoding.default_external = ext if ext
    Encoding.default_internal = int
  rescue => e
    puts "#{ext}/#{int}: cannot set (#{e.class})"; next
  end
  VALUES.each do |name, v|
    report("#{ext}/#{int} #{name}") { [describe(hot(S.new(v, 1))), describe(hot(D.new(1, v))), describe(hot(S.new(v, v))), describe(hot(S.new(Inner.new(v), 2))), describe(hot(D.new(D.new(v, :s), Inner.new(v))))] }
  end
  report("#{ext}/#{int} mixed") { [describe(hot(S.new(VALUES["utf8"], VALUES["eucjp"]))), describe(hot(S.new(VALUES["sym utf8"], VALUES["sjis"])))] }
  Encoding.default_external = old_ext; Encoding.default_internal = old_int
end
