# frozen_string_literal: true
# Runs the benchmark block once untraced, then once while counting the C methods that run
# under a recursion guard: Array / Hash / Struct equality and hashing.

require_relative "../harness/harness-common"

GUARD_TALLY_DIR = File.expand_path("../guard-tally", __dir__)
GUARDED_METHODS = %i[== eql? hash].freeze

def run_benchmark(_hint, **)
  yield

  counts = Hash.new(0)
  total = 0
  tracer = TracePoint.new(:c_call) do |tp|
    total += 1
    next unless GUARDED_METHODS.include?(tp.method_id)

    owner = tp.defined_class
    next unless owner == Array || owner == Hash || owner == Struct || owner == Data

    receiver = tp.self
    size = receiver.size
    counts["#{owner}##{tp.method_id} size #{size < 4 ? size : "4+"}"] += 1
  end
  tracer.enable { yield }

  name = File.basename(File.dirname(File.expand_path($PROGRAM_NAME)))
  lines = ["#{total}\t<all c_calls>"] + counts.sort_by { -_2 }.map { |label, count| "#{count}\t#{label}" }
  File.write(File.join(GUARD_TALLY_DIR, "#{name}.txt"), lines.join("\n") + "\n")
  return_results([], [0.001])
end
