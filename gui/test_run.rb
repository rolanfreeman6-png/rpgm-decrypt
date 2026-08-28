# gui/test_run.rb — headless integration test of the subprocess engine.
# Uses a fake decrypter that mimics rpgm-decrypt's NDJSON + summary contract, so
# we verify spawn + stream parsing without GTK or the real OCaml binary.
# Run: ruby gui/test_run.rb
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require_relative 'core'

dir = Dir.mktmpdir
fake = File.join(dir, 'fake_decrypter.rb')
File.write(fake, <<~RUBY)
  require 'json'
  out = ARGV[-1]
  $stderr.puts({ kind: 'key_found', source: 'www/js/System.json' }.to_json)
  $stderr.puts({ kind: 'detected', path: 'www/img/Title.png_', format: 'MV' }.to_json)
  $stderr.puts({ kind: 'decrypt', input: 'www/img/Title.png_',
                 output: File.join(out, 'www/img/Title.png'), format: 'MV' }.to_json)
  $stderr.puts({ kind: 'detected', path: 'data/Map001.json', format: 'MV' }.to_json)
  $stderr.puts({ kind: 'passthrough', path: 'data/Map001.json' }.to_json)
  puts JSON.generate(scanned: 2, decrypted: 1, passthrough: 1, skipped: 0, failed: 0, key_source: 'x')
RUBY

events = []
result = RpgmDecryptCore.run_decrypt([RbConfig.ruby, fake, '--assets-only', dir, File.join(dir, 'out')]) do |ev|
  events << ev
end

fail "success false: #{result.inspect}" unless result[:success]
fail "unexpected error: #{result[:error]}" if result[:error]
fail "no events captured" if events.empty?
fail "no key_found event" unless events.any? { |e| e['kind'] == 'key_found' }
fail "no decrypt event" unless events.any? { |e| e['kind'] == 'decrypt' }
fail "summary empty" if result[:summary].to_s.strip.empty?

# --- cancellation: the engine must kill the subprocess on cancel ------------
slow = File.join(dir, 'slow_decrypter.rb')
File.write(slow, <<~RUBY)
  require 'json'
  $stderr.puts({ kind: 'detected', path: 'a.png_', format: 'MV' }.to_json)
  $stderr.flush
  sleep 30
RUBY
cancel_flag = false
t0 = Time.now
result2 = RpgmDecryptCore.run_decrypt([RbConfig.ruby, slow], cancel: -> { cancel_flag }) do |ev|
  cancel_flag = true if ev['kind'] == 'detected'
end
elapsed = Time.now - t0
fail 'cancel not honoured (result[:cancelled] not set)' unless result2[:cancelled]
fail 'cancelled run reported success' if result2[:success]
fail "cancel too slow (#{elapsed.round(1)}s)" unless elapsed < 10

FileUtils.rm_rf(dir)
puts "RUN INTEGRATION TEST PASSED (#{events.size} NDJSON events parsed, cancel OK in #{elapsed.round(1)}s)"
