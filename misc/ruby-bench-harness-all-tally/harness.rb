# frozen_string_literal: true
# Runs the benchmark block once untraced, then once while counting every C method call by
# "Owner#method", so that per-call overheads can be weighted by how often a method really runs.

require_relative "../harness/harness-common"

ALL_TALLY_DIR = File.expand_path("../all-tally", __dir__)

def run_benchmark(_hint, **)
  yield

  counts = Hash.new(0)
  tracer = TracePoint.new(:c_call) { |tp| counts[[tp.defined_class, tp.method_id]] += 1 }
  tracer.enable { yield }

  name = File.basename(File.dirname(File.expand_path($PROGRAM_NAME)))
  lines = counts.sort_by { -_2 }.map { |(owner, mid), count| "#{count}\t#{owner.inspect}##{mid}" }
  File.write(File.join(ALL_TALLY_DIR, "#{name}.txt"), lines.join("\n") + "\n")
  return_results([], [0.001])
end
