# Struct#[] / []= with literal and non-literal keys, run often enough to be JIT-compiled.
Point = Struct.new(:x, :y, :z)
Wide = Struct.new(*(1..200).map { :"m#{_1}" })
CASES = {
  "symbol key" => -> { s = Point.new(1, 2, 3); [s[:x], s[:z]] },
  "string key" => -> { Point.new(1, 2, 3)["y"] },
  "index keys" => -> { s = Point.new(1, 2, 3); [s[0], s[2], s[-1], s[-3]] },
  "unknown name" => -> { Point.new(1, 2, 3)[:w] },
  "index out of range" => -> { Point.new(1, 2, 3)[3] },
  "negative out of range" => -> { Point.new(1, 2, 3)[-4] },
  "float index" => -> { Point.new(1, 2, 3)[1.9] },
  "variable key" => -> { k = :y; Point.new(1, 2, 3)[k] },
  "aset symbol" => -> { s = Point.new(1, 2, 3); r = (s[:y] = [9]); [r, s.to_a] },
  "aset index" => -> { s = Point.new(1, 2, 3); s[-1] = :last; s[0] = "first"; s.to_a },
  "aset unknown" => -> { s = Point.new(1, 2, 3); s[:w] = 1 },
  "aset frozen" => -> { s = Point.new(1, 2, 3).freeze; s[:x] = 1 },
  "aset keeps young objects" => -> { s = Point.new; s[:x] = "a" * 20; s[:y] = [1, [2]]; GC.start; [s[:x], s[:y]] },
  "heap struct" => -> { w = Wide.new(*1..200); w[:m200] = :end; [w[:m1], w[:m200], w[199], w[-200]] },
  "subclass" => -> { k = Class.new(Point); s = k.new(1, 2, 3); s[:y] = 5; [s[:y], s[1]] },
}.freeze
CASES.each do |label, body|
  result = nil
  300.times do
    result = begin
      body.call.inspect
    rescue => error
      "#{error.class}: #{error.message} #{error.backtrace_locations.first(2).map(&:label).inspect}"
    end
  end
  puts "#{label}: #{result}"
end
