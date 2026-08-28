# gui/test_core.rb — verifies the GUI's pure logic without GTK or the OCaml
# binary. Run: ruby gui/test_core.rb
require_relative 'core'

# A realistic stream of NDJSON events as emitted by:
#   rpgm-decrypt --log-format json <game> <out>
events = [
  { 'kind' => 'key_found', 'source' => 'www/js/System.json' },
  { 'kind' => 'walked', 'path' => 'www/img/Title.png_', 'size' => 1234 },
  { 'kind' => 'detected', 'path' => 'www/img/Title.png_', 'format' => 'MV' },
  { 'kind' => 'decrypt', 'input' => 'www/img/Title.png_',
    'output' => 'out/www/img/Title.png', 'format' => 'MV' },
  { 'kind' => 'detected', 'path' => 'www/audio/Battle.ogg_', 'format' => 'MV' },
  { 'kind' => 'decrypt', 'input' => 'www/audio/Battle.ogg_',
    'output' => 'out/www/audio/Battle.ogg', 'format' => 'MV' },
  { 'kind' => 'detected', 'path' => 'data/Map001.json', 'format' => 'MV' },
  { 'kind' => 'passthrough', 'path' => 'data/Map001.json' },
  { 'kind' => 'summary', 'scanned' => 3, 'decrypted' => 2, 'failed' => 0 }
]

state = { total: 0, done: 0 }
events.each { |e| RpgmDecryptCore.apply_progress(state, e) }

fail "total: expected 3 got #{state[:total]}" unless state[:total] == 3
fail "done: expected 3 got #{state[:done]}" unless state[:done] == 3
# After 3 detected + 3 processed events the fraction must be exactly 1.0.
frac = RpgmDecryptCore.apply_progress(state, events.last)
fail "fraction not ~1.0: #{frac}" unless (frac - 1.0).abs < 1e-9
# Edge: an MZ archive yields several 'decrypt' events per one 'detected' file,
# so done can exceed total. The GUI clamps the bar (see main.rb apply_event):
over = RpgmDecryptCore.apply_progress(state,
  { 'kind' => 'decrypt', 'input' => 'x', 'output' => 'y', 'format' => 'MZ' })
clamped = [[over, 0.0].max, 1.0].min
fail "clamp failed: #{clamped}" unless (clamped - 1.0).abs < 1e-9

# path mapping — must match the OCaml renames in report.ml
fail 'png_' unless RpgmDecryptCore.map_output_rel('www/img/Title.png_') == 'www/img/Title.png'
fail 'rpgmvp' unless RpgmDecryptCore.map_output_rel('a/b.rpgmvp') == 'a/b.png'
fail 'ogg_' unless RpgmDecryptCore.map_output_rel('www/audio/Battle.ogg_') == 'www/audio/Battle.ogg'
fail 'rpgmvm' unless RpgmDecryptCore.map_output_rel('x/y.rpgmvm') == 'x/y.m4a'
fail 'pass-through' unless RpgmDecryptCore.map_output_rel('data/Map001.json') == 'data/Map001.json'

# human log lines
unless RpgmDecryptCore.human_line({ 'kind' => 'decrypt', 'format' => 'MV',
                                     'input' => 'i', 'output' => 'o' }) == '  ▶ MV: i → o'
  fail 'human decrypt line'
end
fail 'nil for unknown' unless RpgmDecryptCore.human_line({ 'kind' => 'walked' }).nil?

puts 'CORE TESTS PASSED'
