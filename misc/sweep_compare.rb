# Runs struct_scope_sweep.rb with two builds and prints class / Struct / Data before and after.
# Usage: ruby sweep_compare.rb BASE_RUBY PATCHED_RUBY [RUBY_OPTION...]
base, patched, *options = ARGV
script = File.join(__dir__, "struct_scope_sweep.rb")
parse = ->(ruby) {
  IO.popen([ruby, "--disable-gems", *options, script], &:readlines).drop(1).to_h { |line|
    label = line[0, 30].strip
    [label, line[30..].split.first(3)]
  }
}
before = parse.(base)
after = parse.(patched)
puts format("%-30s %7s | %8s %8s | %8s %8s", "operation", "class", "Struct", "patched", "Data", "patched")
before.each do |label, (plain, struct, data)|
  _, struct_after, data_after = after.fetch(label)
  puts format("%-30s %7s | %8s %8s | %8s %8s", label, plain, struct, struct_after, data, data_after)
end
