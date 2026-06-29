# frozen_string_literal: true
#
# size_probe.rb — measure the RESIDENT PSS of each refork_gate dataset shape at candidate N (Linux only).
# A blob is 16 B/record but a hash is ~200 B/record, so a single N can't hit a target size across shapes.
# Each (shape, N) is built in its OWN forked child and measured against an empty baseline, so heap drift /
# GC fragmentation from a prior build never contaminates the next measurement.
#
#   NS_HASH=1000000,2000000 NS_STRUCT=2000000,4000000 NS_BLOB=12000000,25000000 \
#     docker run --rm -v "$PWD":/app -w /app ruby:4.0-slim ruby size_probe.rb

abort "Linux only — no /proc/smaps_rollup on #{RUBY_PLATFORM}" unless File.exist?("/proc/self/smaps_rollup")

Rec = Data.define(:threshold, :factor, :base)
BLOB_FMT = "lld"
BLOB_SIZE = 16

def field_values(i) = [i % 1000, ((i * 37) % 100) / 100.0, i % 50]

def build(shape, n)
  case shape
  when :hash   then Array.new(n) { |i| t, f, b = field_values(i); { threshold: t, factor: f, base: b } }
  when :struct then Array.new(n) { |i| t, f, b = field_values(i); Rec.new(threshold: t, factor: f, base: b) }
  when :blob   then (+"").tap { |s| n.times { |i| t, f, b = field_values(i); s << [t, b, f].pack(BLOB_FMT) } }
  else abort "unknown shape #{shape}"
  end
end

def pss_mb
  kb = File.read("/proc/self/smaps_rollup")[/^Pss:\s+(\d+)\s+kB/, 1].to_i
  (kb / 1024.0).round(1)
end

def ns_for(shape)
  (ENV["NS_#{shape.to_s.upcase}"] || ENV["NS"] || "1000000,2000000,4000000").split(",").map { Integer(_1) }
end

SHAPES = (ENV["SHAPES"] || "hash,struct,blob").split(",").map(&:to_sym)

puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}) dataset size probe"
printf "%-7s %12s %12s %12s %14s\n", "shape", "N", "count", "resident_MB", "bytes/record"
SHAPES.each do |shape|
  ns_for(shape).each do |n|
    rd, wr = IO.pipe
    pid = fork do
      rd.close
      ds = build(shape, n)
      GC.start
      resident = pss_mb
      cnt = shape == :blob ? ds.bytesize / BLOB_SIZE : ds.length
      wr.write([resident, cnt].join(","))
      wr.close
      exit!(0)
    end
    wr.close
    line = rd.read
    rd.close
    Process.wait(pid)
    abort "size_probe child died (OOM at #{shape} N=#{n}?)" if line.empty?
    resident, cnt = line.split(",")
    resident = resident.to_f
    cnt = cnt.to_i
    printf "%-7s %12d %12d %12.1f %14.1f\n", shape, n, cnt, resident, resident * 1024 * 1024 / cnt
  end
end
