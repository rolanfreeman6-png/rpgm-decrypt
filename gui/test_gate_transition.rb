# gui/test_gate_transition.rb — automated check of the "gate → main window"
# hand-over (the path that used to die silently after unlock). No network:
# the :starred event is injected directly. A real display is required.
# Run: ruby gui/test_gate_transition.rb
ENV['RPGM_GUI_BUILD'] = '1' # skip the real bootstrap at the bottom of main.rb
require_relative 'main'

Gtk.init
RpgmGui.apply_style

gate = GateWindow.new
result = { main_window_seen: false, error: nil }

GLib::Idle.add do
  begin
    # Fake the completed verification: unlock flag + Unlocked screen…
    gate.send(:handle_event, :starred, 'selftest')
    # …then close the gate exactly like the "Start decrypting" button does.
    gate.instance_variable_get(:@window).destroy
  rescue StandardError => e
    result[:error] = "#{e.class}: #{e.message}"
    Gtk.main_quit
  end
  false
end

# Give the hand-over idle a moment, then verify the main window exists.
GLib::Timeout.add(2500) do
  titles = Gtk::Window.toplevels.map(&:title).compact
  result[:main_window_seen] = titles.include?('rpgm decrypt')
  Gtk.main_quit
  false
end

Gtk.main

Gtk.main

fail "hand-over error: #{result[:error]}" if result[:error]
fail 'main window did not appear after the gate closed' unless result[:main_window_seen]

puts 'GATE TRANSITION TEST PASSED (gate unlocked → main window took over)'
# Cleanup after the verdict — destroying toplevels post-main-quit can raise.
begin
  Gtk::Window.toplevels.each(&:destroy)
rescue StandardError
  nil
end
