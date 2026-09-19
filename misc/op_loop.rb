# Tight loop over one Struct operation, for perf. Usage: ruby op_loop.rb hash|deconstruct|aref|new
S3 = Struct.new(:x, :y, :z)

def run_hash(s, n) = (i = 0; while i < n; s.hash; i += 1; end)
def run_deconstruct(s, n) = (i = 0; keys = %i[x y]; while i < n; s.deconstruct_keys(keys); i += 1; end)
def run_aref(s, n) = (i = 0; while i < n; s[:y]; i += 1; end)
def run_new(s, n) = (i = 0; while i < n; S3.new(1, 2, 3); i += 1; end)

s = S3.new(1, "k", :sym)
200.times { send(:"run_#{ARGV[0]}", s, 1_000) }
send(:"run_#{ARGV[0]}", s, 30_000_000)
