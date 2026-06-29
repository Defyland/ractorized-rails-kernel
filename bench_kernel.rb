# frozen_string_literal: true
#
# bench_kernel.rb — shared primitives for the Ractorized Rails Kernel A1/A2/refork harnesses.
#
# Pure and PARAMETERIZED (no ENV reads, no global constants): every harness measures the SAME kernel,
# so their numbers are comparable. Extracted to end the "copied verbatim" drift the review flagged.
# Hash shape only (the niche shape). `work` captures GC.stat deltas so the allocation→CoW mechanism
# is MEASURED, not inferred.
module BenchKernel
  module_function

  def build_dataset(n)
    Array.new(n) { |i| { threshold: i % 1000, factor: ((i * 37) % 100) / 100.0, base: i % 50 } }
  end

  def compute(dataset, count, item, scan)
    start = item[:seed] % (count - scan)
    v = item[:value]
    acc = 0.0
    scan.times do |j|
      r = dataset[start + j]
      acc += r[:factor] * (v + r[:base]) if v > r[:threshold]
    end
    acc
  end

  def churn(n) = n.times { |i| { k: i, a: [i, i] } }
  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def make_items(n) = Array.new(n) { |i| { id: i, seed: i * 7919, value: (i * 13) % 1500 } }
  def shard(items, pool, idx) = items.each_slice((items.size / pool.to_f).ceil).to_a.fetch(idx, [])

  # sustained loop until `deadline`; first-pass checksum for correctness; GC.stat deltas as proof
  def work(dataset, count, items, scan, alloc, deadline)
    g0 = GC.stat
    t0 = mono
    done = 0; cksum = 0.0; first_pass = false
    until mono > deadline
      items.each do |it|
        acc = compute(dataset, count, it, scan)
        churn(alloc) unless alloc.zero?
        cksum += acc unless first_pass
        done += 1
      end
      first_pass = true
    end
    g1 = GC.stat
    { done: done, elapsed: mono - t0, cksum: cksum.round(4), full_pass: first_pass,
      gc_count: g1[:count] - g0[:count],
      gc_time_ms: (g1[:time] || 0) - (g0[:time] || 0),
      alloc_objs: g1[:total_allocated_objects] - g0[:total_allocated_objects] }
  end

  # run EXACTLY `passes` full passes over `items` (not a time deadline) — guarantees a complete pass per
  # generation, so refork generations are always valid however short. First-pass checksum for correctness.
  def work_passes(dataset, count, items, scan, alloc, passes)
    g0 = GC.stat
    t0 = mono
    done = 0; cksum = 0.0
    passes.times do |p|
      items.each do |it|
        acc = compute(dataset, count, it, scan)
        churn(alloc) unless alloc.zero?
        cksum += acc if p.zero?
        done += 1
      end
    end
    g1 = GC.stat
    { done: done, elapsed: mono - t0, cksum: cksum.round(4), full_pass: passes >= 1,
      gc_count: g1[:count] - g0[:count], gc_time_ms: (g1[:time] || 0) - (g0[:time] || 0),
      alloc_objs: g1[:total_allocated_objects] - g0[:total_allocated_objects] }
  end

  def smaps(pid = Process.pid)
    txt = File.read("/proc/#{pid}/smaps_rollup")
    grab = lambda do |key|
      m = txt[/^#{key}:\s+(\d+)\s+kB/, 1]
      raise "smaps: field #{key} not found for pid #{pid}" if m.nil?
      Integer(m)
    end
    { pss: grab["Pss"], pdirty: grab["Private_Dirty"], sclean: grab["Shared_Clean"] }
  rescue Errno::ENOENT
    raise "smaps: process #{pid} gone before snapshot (OOM/crash?)"
  end

  def isolated
    r, w = IO.pipe
    pid = fork do
      r.close
      w.write(Marshal.dump(yield)); w.close
      exit!(0)
    end
    w.close
    data = r.read; r.close
    raise "isolated child #{pid} died without output (OOM?)" if data.empty?
    Process.wait(pid)
    Marshal.load(data)
  ensure
    r.close unless r.closed?
  end

  def median(xs) = xs.sort.then { |s| s.length.odd? ? s[s.length / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2.0 }
end
