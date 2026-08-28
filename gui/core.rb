# gui/core.rb — pure, GUI-toolkit-free logic for rpgm-decrypt-gui.
#
# Shared by main.rb (GTK) and the test suite so the decryption-progress
# parsing and path mapping can be verified without a display or the OCaml
# binary. No GTK here; the subprocess engine uses Open3 (still headless).

require 'json'
require 'open3'

ENCRYPTED_ASSET_EXT = {
  '.png_' => 'png', '.rpgmvp' => 'png',
  '.ogg_' => 'ogg', '.rpgmvo' => 'ogg',
  '.m4a_' => 'm4a', '.rpgmvm' => 'm4a'
}.freeze

ARCHIVE_EXT = %w[.rgssad .rgss2a .rgss3a].freeze

module RpgmDecryptCore
  # Map an encrypted input relative path to the decrypted output relative path
  # using the same renaming rule the OCaml tool applies (MV assets only).
  def self.map_output_rel(rel)
    ext = File.extname(rel).downcase
    if (kind = ENCRYPTED_ASSET_EXT[ext])
      dir = File.dirname(rel)
      base = File.basename(rel, ext)
      File.join(dir == '.' ? '' : dir, base + '.' + kind)
    else
      rel
    end
  end

  # Update a progress state ({total:, done:}) from one NDJSON event and return
  # the new fraction (Float, 0..1) or nil when the total is still unknown.
  def self.apply_progress(state, ev)
    case ev['kind']
    when 'detected' then state[:total] += 1
    when 'decrypt', 'passthrough', 'skipped', 'failed' then state[:done] += 1
    end
    state[:total].positive? ? (state[:done].to_f / state[:total]) : nil
  end

  # Human-readable one-line description of an NDJSON event (for the log view).
  def self.human_line(ev)
    case ev['kind']
    when 'decrypt' then "  ▶ #{ev['format']}: #{ev['input']} → #{ev['output']}"
    when 'passthrough' then "  = #{ev['path']} (already plain)"
    when 'skipped' then "  - #{ev['path']} (#{ev['reason']})"
    when 'failed' then "  ✗ #{ev['path']} (#{ev['reason']})"
    when 'key_found' then "  [key] #{ev['source']}"
    when 'detected' then "  + #{ev['path']} → #{ev['format']}"
    when 'raw' then ev['text'].to_s
    else nil
    end
  end

  # Parse one NDJSON line from the decrypter's stderr. Non-JSON lines are
  # surfaced as {kind:'raw', text:} so the UI can still show them.
  def self.parse_line(line)
    JSON.parse(line)
  rescue JSON::ParserError
    { 'kind' => 'raw', 'text' => line }
  end

  # Headless engine: spawn the OCaml decrypter, parse its NDJSON progress stream
  # from stderr (calling +on_event+ per event on a reader thread), capture the
  # final summary from stdout, and return {success:, summary:, cancelled:, error:}.
  # The caller is responsible for threading/UI marshalling. When the +cancel+
  # proc is given and starts returning true, the subprocess is terminated.
  def self.run_decrypt(args, cancel: nil, &on_event)
    success = false
    cancelled = false
    summary_text = +''
    begin
      Open3.popen3(*args) do |_i, o, e, t|
        _i.close
        pid = t.pid
        cancel_t =
          if cancel
            Thread.new do
              until cancel.call
                sleep 0.1
              end
              begin
                Process.kill('KILL', pid)
              rescue StandardError
                nil
              end
            end
          end
        err_t = Thread.new { e.each_line { |l| on_event.call(parse_line(l.chomp)) if on_event } }
        summary_text = o.read.to_s
        err_t.join
        cancel_t&.kill
        cancelled = cancel ? cancel.call : false
        code = t.value.exitstatus
        # A cancelled run is never a success — on Windows TerminateProcess can
        # surface as exit code 0, so the flag must win over the exit status.
        success = !cancelled && (code == 0 || code == 5)
      end
    rescue Errno::ENOENT => ex
      return { success: false, summary: '', cancelled: false, error: ex.message }
    end
    { success: success, summary: summary_text, cancelled: cancelled }
  end
end
