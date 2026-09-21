# Data#with given a block, from every kind of call site
def report(label) = puts("#{label}: #{(yield).inspect}") rescue puts("#{label}: #{$!.class}: #{$!.message}")
D = Data.define(:x, :y); o = D.new(1, 2)
def lit(o) = o.with(y: 5) { 1 }
def lit_pairs(o) = o.with(y: 5) { |k, v| [k, v] }
def splat(o, h) = o.with(**h) { 1 }
def none(o) = o.with { 1 }
def blockarg(o, &b) = o.with(y: 5, &b)
def via_send(o) = o.send(:with, y: 5) { 1 }
300.times { lit(o) rescue nil; lit_pairs(o) rescue nil; splat(o, { y: 5 }) rescue nil; none(o); blockarg(o); blockarg(o) { 1 } rescue nil; via_send(o) rescue nil }
report("literal") { lit(o) }
report("literal, block returns pairs") { lit_pairs(o) }
report("splat") { splat(o, { y: 5 }) }
report("no keywords") { none(o) }
report("block argument") { [blockarg(o), (blockarg(o) { 1 } rescue $!.class), blockarg(o) { |k, v| [k, v] }] }
report("send") { via_send(o) }
