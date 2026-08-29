# gui/test_gate.rb — offline unit tests for the star gate logic (no network,
# no GTK). Live device-flow check: RPGM_GATE_LIVE=1 ruby gui/test_gate.rb
require 'tmpdir'
require 'fileutils'
require_relative 'star_gate'

# --- constants configured ---------------------------------------------------
fail 'REPO_URL must be a real repo' unless RpgmStarGate::REPO_URL =~ %r{https://github\.com/[^/]+/[^/]+}
fail 'OWNER_REPO must match REPO_URL' unless RpgmStarGate::REPO_URL.end_with?(RpgmStarGate::OWNER_REPO)
fail 'OAUTH_CLIENT_ID must be a real GitHub OAuth app id' unless
  RpgmStarGate::OAUTH_CLIENT_ID.start_with?('Ov', 'Iv')

# --- device-code response shape (as github.com/login/device/code returns) ---
device_json = '{"device_code":"dc_abc","user_code":"WDJB-MJHT",' \
              '"verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}'
v = JSON.parse(device_json)
fail 'device_code missing' if v['device_code'].empty? || v['user_code'].empty?

# --- poll response classification (mirror of poll_access_token's mapping) ---
{ 'authorization_pending' => :pending, 'slow_down' => :slow_down,
  'expired_token' => :expired, 'access_denied' => :denied }.each do |err, expected|
  mapped = case err
           when 'authorization_pending' then :pending
           when 'slow_down' then :slow_down
           when 'expired_token' then :expired
           when 'access_denied' then :denied
           else :failed
           end
  fail "poll classify #{err}: #{mapped}" unless mapped == expected
end

# --- verify_star_with_token: :not_starred must carry the token for re-checks,
#     :starred / :failed must not. (verify_star is stubbed — pure logic test.)
RpgmStarGate.define_singleton_method(:verify_star) { |token| @stub ||= [:not_starred, 'alice'] }
res = RpgmStarGate.verify_star_with_token('tok1')
fail "not_starred must carry token: #{res.inspect}" unless res == [:not_starred, 'alice', 'tok1']

RpgmStarGate.define_singleton_method(:verify_star) { |_token| [:starred, 'alice'] }
res = RpgmStarGate.verify_star_with_token('tok1')
fail "starred must not carry token: #{res.inspect}" unless res == [:starred, 'alice']

# --- unlock persistence round-trip ------------------------------------------
dir = Dir.mktmpdir
fail 'no unlock on fresh machine' unless RpgmStarGate.load_unlock(dir).nil?
RpgmStarGate.save_unlock(dir, 'rolanfreeman6-png')
fail "unlock not persisted: #{RpgmStarGate.load_unlock(dir).inspect}" unless
  RpgmStarGate.load_unlock(dir) == 'rolanfreeman6-png'
File.write(RpgmStarGate.config_path(dir), '{broken json')
fail 'broken config must not crash boot' unless RpgmStarGate.load_unlock(dir).nil?
FileUtils.rm_rf(dir)

# --- run_device_flow event contract with a stubbed network layer ------------
RpgmStarGate.define_singleton_method(:request_device_code) do
  [['dc_1', 'WDJB-MJHT', 'https://github.com/login/device', 1, 900], nil]
end
RpgmStarGate.define_singleton_method(:poll_access_token) do |_dc|
  @polls = (@polls || 0) + 1
  @polls >= 2 ? [:token, 'tok9'] : :pending
end
RpgmStarGate.define_singleton_method(:verify_star) { |_t| [:starred, 'bob'] }
events = []
RpgmStarGate.run_device_flow(->(kind, *args) { events << [kind, args] })
fail "expected device_code then starred, got #{events.inspect}" unless
  events.map(&:first) == %i[device_code starred]
fail 'bad user_code event' unless events[0][1] == ['WDJB-MJHT', 'https://github.com/login/device']
fail 'bad login' unless events[1][1] == ['bob']

# --- denial path -------------------------------------------------------------
RpgmStarGate.define_singleton_method(:poll_access_token) { |_dc| :denied }
events.clear
RpgmStarGate.run_device_flow(->(kind, *args) { events << [kind, args] })
fail "denied path: #{events.inspect}" unless events.last[0] == :denied

# --- optional live check: a real device code can be issued -------------------
if ENV['RPGM_GATE_LIVE']
  triple, err = RpgmStarGate.request_device_code
  fail "live device code failed: #{err}" if err
  puts "LIVE device code issued: #{triple[1]} (valid #{triple[4]}s, do NOT authorize it)"
end

puts 'GATE TESTS PASSED'
