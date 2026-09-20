# Tight Struct#inspect loop for perf. Usage: ruby inspect_loop.rb
S3 = Struct.new(:x, :y, :z)
def run(s, n) = (i = 0; while i < n; s.inspect; i += 1; end)
s = S3.new(1, 2, 3)
200.times { run(s, 500) }
run(s, 8_000_000)
