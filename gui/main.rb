#!/usr/bin/env ruby
# frozen_string_literal: true

# rpgm-decrypt GUI — native Windows front-end (Ruby + GTK3) for the OCaml
# rpgm-decrypt decrypter.
#
# The OCaml binary is treated as a black box: this GUI just launches
# `rpgm-decrypt.exe` as a subprocess and parses its NDJSON progress stream
# (--log-format json). Two modes:
#   * "Whole game"  — decrypt a whole game folder (mirror copy or --assets-only).
#   * "Single file" — point-decrypt a single asset: decrypt the game to a temp
#                        dir, grab the one decrypted file, then "return" it to the
#                        game folder (with a .bak backup of the original).

require 'json'
require 'open3'
require 'fileutils'
require 'find'
require 'pathname'
require_relative 'core'
require_relative 'star_gate'

# --- locate the directory this executable lives in -------------------------
EXE_DIR = File.dirname(ENV['OCRA_EXECUTABLE'] || File.expand_path($PROGRAM_NAME))

# Make sure the bundled GTK3 runtime (which ships next to this .exe after OCRA
# extraction) is found. These MUST be set BEFORE requiring gtk3, because the
# gtk3 gem loads libgtk + GObject-Introspection typelibs at require time.
ENV['PATH'] = [EXE_DIR, File.join(EXE_DIR, 'bin'), ENV['PATH']]
              .reject { |p| p.nil? || p.empty? }
              .join(File::PATH_SEPARATOR)
ENV['GTK_PATH'] = EXE_DIR if ENV['GTK_PATH'].nil? || ENV['GTK_PATH'].empty?
# GObject-Introspection typelibs (Gtk-3.0.typelib, Gdk-3.0.typelib, …).
gi = File.join(EXE_DIR, 'lib', 'girepository-1.0')
ENV['GI_TYPELIB_PATH'] = gi if ENV['GI_TYPELIB_PATH'].nil? || ENV['GI_TYPELIB_PATH'].empty?
# gdk-pixbuf image loaders (icons/themes). Pick the loaders dir that actually
# exists in the bundle — the staged layout may drop the gdk-pixbuf-2.0 level.
gp = [File.join(EXE_DIR, 'lib', 'gdk-pixbuf-2.0', '2.10.0', 'loaders'),
      File.join(EXE_DIR, 'lib', '2.10.0', 'loaders')]
     .find { |d| File.directory?(d) }
ENV['GDK_PIXBUF_MODULEDIR'] = gp if gp && ENV['GDK_PIXBUF_MODULEDIR'].to_s.empty?
# CA store bundled next to the exe (see build_windows.ps1): OpenSSL's
# compiled-in cert path only exists on dev machines, so point it at the
# bundled store BEFORE any TLS is used (star gate / net/http).
cert_file = File.join(EXE_DIR, 'cacert.pem')
ENV['SSL_CERT_FILE'] = cert_file if File.exist?(cert_file)

# On RubyInstaller (Ruby 3.x) the Windows loader does NOT search PATH for a
# native extension's dependent DLLs, so the bundled GTK/GLib DLLs that ship
# next to this .exe must be registered as an explicit DLL search directory
# BEFORE `require 'gtk3'`. Otherwise glib2.so fails to load with Win32 error
# 126 ("the specified module could not be found"). In a dev checkout the
# ruby-gnome gems add the MSYS2 runtime dir themselves; in the packaged bundle
# the DLLs live beside the executable instead.
dll_dirs = [EXE_DIR, File.join(EXE_DIR, 'bin')].select { |d| File.directory?(d) }
begin
  require 'ruby_installer/runtime'
  dll_dirs.each { |d| RubyInstaller::Runtime.add_dll_directory(d) }
rescue LoadError
  # Fallback when ruby_installer/runtime isn't bundled: call the Win32 API
  # directly via fiddle (a core library, always present in the bundle).
  begin
    require 'fiddle'
    k32 = Fiddle.dlopen('kernel32')
    set_default_dirs = Fiddle::Function.new(
      k32['SetDefaultDllDirectories'], [Fiddle::TYPE_INT], Fiddle::TYPE_INT
    )
    add_dll_dir = Fiddle::Function.new(
      k32['AddDllDirectory'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP
    )
    set_default_dirs.call(0x00001000) # LOAD_LIBRARY_SEARCH_DEFAULT_DIRS
    dll_dirs.each do |d|
      wide = (d.tr('/', '\\') + "\0").encode(Encoding::UTF_16LE)
      add_dll_dir.call(wide)
    end
  rescue StandardError => e
    warn "[rpgm-gui] DLL directory setup failed: #{e.class}: #{e.message}"
  end
end

require 'gtk3'

def find_ocaml_exe
  candidates = []
  candidates << ENV['RPGM_DECRYPT_EXE'] if ENV['RPGM_DECRYPT_EXE'] && !ENV['RPGM_DECRYPT_EXE'].empty?
  candidates << File.join(EXE_DIR, 'rpgm-decrypt.exe')
  repo = File.expand_path(File.join(EXE_DIR, '..', '..'))
  candidates << File.join(repo, 'ocaml', 'dist-win', 'rpgm-decrypt.exe')
  candidates << 'rpgm-decrypt.exe'
  candidates.compact.find { |p| p && File.exist?(p) }
end

OCAML_EXE = find_ocaml_exe

# ---------------------------------------------------------------------------
class RpgmGui
  def initialize
    @state = { total: 0, done: 0, summary: nil }
    @running = false
    @point_cache = nil # { decrypted:, original:, rel: }
    @cancel_requested = false

    build_window
    @window.show_all
  end

  # Scarlet-neon theme over a light background. Neon (glow) is applied to the
  # accent elements — the title, buttons, focused input, active tab, progress
  # fill and the framed log/list areas — while the *inner* content widgets
  # (treeview/textview) stay glow-free so the glow no longer bleeds inside them.
  # A class method so the star-gate window can reuse the exact same theme.
  def self.apply_style
    css = <<~CSS
      /* Stylish, slightly emphasized UI font (kept tasteful) */
      * { font-family: "Trebuchet MS", "Segoe UI", sans-serif; }

      /* Base surface */
      window, .background { background-color: #f6f7f9; }
      label { color: #232323; font-size: 11pt; letter-spacing: 0.3px; }

      /* ONE big neon frame around the whole program */
      .app-frame {
        background-color: #f6f7f9;
        border: 3px solid #ff1f4b;
        border-radius: 16px;
        box-shadow: 0 0 16px rgba(255, 31, 75, 0.6);
        padding: 14px;
      }

      /* Neon scarlet title */
      .app-title {
        color: #ff1f4b;
        font-size: 25px;
        font-weight: 600;
        letter-spacing: 0.6px;
        text-shadow: 0 0 8px rgba(255, 31, 75, 0.95),
                     0 0 18px rgba(255, 31, 75, 0.55);
      }

      /* Buttons: subtle scarlet accent (no big outline) */
      button {
        background-image: none;
        background-color: #ffffff;
        color: #1c1c1c;
        font-weight: 500;
        border: 1px solid #ccd0d6;
        border-radius: 9px;
        padding: 5px 14px;
        margin: 4px 6px;
      }
      button:hover  { background-color: #fff0f3; }
      button:active { background-color: #ffd9e1; }
      button:disabled { border-color: #e0e0e0; color: #a6a6a6; box-shadow: none; }

      /* Inputs: neutral border, scarlet only on focus */
      entry {
        background-color: #ffffff;
        border: 1px solid #ccd0d6;
        border-radius: 8px;
        padding: 4px 8px;
      }
      entry:focus { border-color: #ff1f4b; box-shadow: 0 0 7px rgba(255, 31, 75, 0.6); }

      /* Tabs: NO neon outline/glow — just bold scarlet text on the active tab */
      notebook > header { background-color: transparent; }
      notebook > header > tabs > tab {
        padding: 5px 16px;
        color: #5a5a5a;
        border: none;
        box-shadow: none;
      }
      notebook > header > tabs > tab:checked { color: #ff1f4b; font-weight: 500; }

      /* Progress bar: neutral trough, scarlet fill (no outline) */
      progressbar > trough { background-color: #e9ebef; border-radius: 8px; }
      progressbar > trough > progress {
        background-image: none;
        background-color: #ff1f4b;
        border-radius: 8px;
      }
      progressbar text { color: #232323; }
    CSS
    provider = Gtk::CssProvider.new
    provider.load(data: css)
    Gtk::StyleContext.add_provider_for_screen(
      Gdk::Screen.default, provider, Gtk::StyleProvider::PRIORITY_APPLICATION
    )
  rescue StandardError => e
    warn "[rpgm-gui] style setup failed: #{e.class}: #{e.message}"
  end

  def build_window
    @window = Gtk::Window.new('rpgm decrypt')
    @window.resizable = true
    @window.set_default_size(960, 680)
    @window.signal_connect('destroy') { Gtk.main_quit }

    # Scarlet-diamond window/taskbar icon (ships next to the .exe).
    icon_file = [File.join(EXE_DIR, 'rpgm-decrypt.png'),
                 File.join(EXE_DIR, 'rpgm-decrypt.ico')].find { |p| File.exist?(p) }
    if icon_file
      begin
        @window.icon = GdkPixbuf::Pixbuf.new(file: icon_file)
      rescue StandardError => e
        warn "[rpgm-gui] window icon load failed: #{e.class}: #{e.message}"
      end
    end

    root = Gtk::Box.new(:vertical, 8)
    # One big neon frame wraps the whole program; margin leaves room for its glow.
    root.style_context.add_class('app-frame')
    root.margin = 12

    # Centered header: neon diamond icon + neon scarlet title side by side.
    header_box = Gtk::Box.new(:horizontal, 10)
    header_box.halign = :center

    if icon_file
      begin
        pb = GdkPixbuf::Pixbuf.new(file: icon_file).scale_simple(36, 36, :bilinear)
        header_box.pack_start(Gtk::Image.new(pixbuf: pb), expand: false, fill: false, padding: 0)
      rescue StandardError => e
        warn "[rpgm-gui] header icon load failed: #{e.class}: #{e.message}"
      end
    end

    header = Gtk::Label.new
    header.markup = 'rpgm decrypt'
    header.style_context.add_class('app-title')
    header_box.pack_start(header, expand: false, fill: false, padding: 0)
    root.pack_start(header_box, expand: false, fill: false, padding: 0)

    subtitle = Gtk::Label.new('front-end for rpgm-decrypt.exe (OCaml)')
    subtitle.halign = :center
    root.pack_start(subtitle, expand: false, fill: false, padding: 0)

    nb = Gtk::Notebook.new
    nb.append_page(build_bulk_tab, Gtk::Label.new('Whole game'))
    nb.append_page(build_point_tab, Gtk::Label.new('Single file'))
    root.pack_start(nb, expand: true, fill: true, padding: 0)

    # shared progress + stop + status + log
    @progress = Gtk::ProgressBar.new
    @progress.show_text = true
    @progress.text = 'ready'

    @stop_btn = Gtk::Button.new(label: 'Stop')
    @stop_btn.sensitive = false
    @stop_btn.signal_connect('clicked') { request_cancel }

    prog_row = Gtk::Box.new(:horizontal, 6)
    prog_row.pack_start(@progress, expand: true, fill: true, padding: 0)
    prog_row.pack_start(@stop_btn, expand: false, fill: false, padding: 0)
    root.pack_start(prog_row, expand: false, fill: false, padding: 0)

    @status = Gtk::Label.new('idle')
    @status.xalign = 0.0
    save_btn = Gtk::Button.new(label: 'Save log...')
    save_btn.signal_connect('clicked') { save_log }
    status_row = Gtk::Box.new(:horizontal, 6)
    status_row.pack_start(@status, expand: true, fill: true, padding: 0)
    status_row.pack_start(save_btn, expand: false, fill: false, padding: 0)
    root.pack_start(status_row, expand: false, fill: false, padding: 0)

    @log_buf = Gtk::TextBuffer.new
    @log_view = Gtk::TextView.new(@log_buf)
    @log_view.editable = false
    @log_view.wrap_mode = :word
    sw = Gtk::ScrolledWindow.new
    sw.set_size_request(-1, 180)
    sw.add(@log_view)
    root.pack_start(sw, expand: false, fill: false, padding: 0)

    if OCAML_EXE.nil?
      log('[ERROR] rpgm-decrypt.exe not found next to the GUI. Put rpgm-decrypt.exe and zlib1.dll in the same folder.')
    else
      log("Using decrypter: #{OCAML_EXE}")
    end

    @window.add(root)
  end

  # ---- "Вся игра" tab ------------------------------------------------------
  def build_bulk_tab
    box = Gtk::Box.new(:vertical, 8)

    @game_entry = file_chooser('Source game folder', :select_folder)
    @out_entry = file_chooser('Output folder', :select_folder)
    @game_entry.signal_connect('file-set') do
      g = @game_entry.filename
      @out_entry.set_filename(g + '-decrypted') if g && @out_entry.filename.to_s.empty?
    end

    @assets_only = Gtk::CheckButton.new('Assets only (--assets-only)')
    @dry_run = Gtk::CheckButton.new('Dry run (--dry-run, nothing is written)')
    key_box, @key_type, @key_entry = build_key_row

    run = Gtk::Button.new(label: 'Decrypt game')
    run.signal_connect('clicked') { run_bulk }
    open_out = Gtk::Button.new(label: 'Open output folder')
    open_out.signal_connect('clicked') do
      o = @out_entry.filename
      if o && File.directory?(o)
        open_path(o)
      else
        log('[!] Select the output folder first.')
      end
    end

    box.pack_start(@game_entry, expand: false, fill: false, padding: 0)
    box.pack_start(@out_entry, expand: false, fill: false, padding: 0)
    box.pack_start(@assets_only, expand: false, fill: false, padding: 0)
    box.pack_start(@dry_run, expand: false, fill: false, padding: 0)
    box.pack_start(key_box, expand: false, fill: false, padding: 0)
    btn_row = Gtk::Box.new(:horizontal, 6)
    btn_row.pack_start(run, expand: false, fill: false, padding: 0)
    btn_row.pack_start(open_out, expand: false, fill: false, padding: 0)
    box.pack_start(btn_row, expand: false, fill: false, padding: 0)
    box
  end

  # ---- "Один файл" tab -----------------------------------------------------
  def build_point_tab
    box = Gtk::Box.new(:vertical, 8)

    @p_game_entry = file_chooser('Game folder', :select_folder)
    refresh = Gtk::Button.new(label: 'Refresh file list')
    refresh.signal_connect('clicked') { refresh_list }

    @filter = Gtk::Entry.new
    @filter.placeholder_text = 'filter by name (substring)...'
    # Filter keystrokes only re-populate the view; the folder rescan is
    # triggered by "Refresh file list" / picking a game folder.
    @filter.signal_connect('changed') { populate_tree(@filter.text.to_s) }

    # file list
    @store = Gtk::ListStore.new(String, String, String) # rel, size, status
    @tree = Gtk::TreeView.new(@store)
    @tree.append_column(Gtk::TreeViewColumn.new('Path', Gtk::CellRendererText.new, text: 0))
    @tree.append_column(Gtk::TreeViewColumn.new('Size', Gtk::CellRendererText.new, text: 1))
    @tree.append_column(Gtk::TreeViewColumn.new('Status', Gtk::CellRendererText.new, text: 2))
    @tree.selection.signal_connect('changed') do |sel|
      it = sel.selected
      @selected_rel = it ? it[0] : nil
    end
    list_sw = Gtk::ScrolledWindow.new
    list_sw.set_size_request(-1, 260)
    list_sw.add(@tree)

    point_dec = Gtk::Button.new(label: 'Decrypt selected')
    point_dec.signal_connect('clicked') { point_decrypt }
    @return_btn = Gtk::Button.new(label: 'Restore in place (decrypted)')
    @return_btn.sensitive = false
    @return_btn.signal_connect('clicked') { return_to_place }
    open_dec = Gtk::Button.new(label: 'Open decrypted')
    open_dec.signal_connect('clicked') { open_path(@point_cache && @point_cache[:decrypted]) }

    box.pack_start(@p_game_entry, expand: false, fill: false, padding: 0)
    box.pack_start(refresh, expand: false, fill: false, padding: 0)
    box.pack_start(@filter, expand: false, fill: false, padding: 0)
    box.pack_start(list_sw, expand: true, fill: true, padding: 0)
    box.pack_start(point_dec, expand: false, fill: false, padding: 0)
    row = Gtk::Box.new(:horizontal, 8)
    row.pack_start(@return_btn, expand: false, fill: false, padding: 0)
    row.pack_start(open_dec, expand: false, fill: false, padding: 0)
    box.pack_start(row, expand: false, fill: false, padding: 0)
    box
  end

  # ---- shared widgets ------------------------------------------------------
  def file_chooser(label, action)
    btn = Gtk::FileChooserButton.new(label, action)
    btn.width_request = 640
    btn
  end

  def build_key_row
    box = Gtk::Box.new(:horizontal, 6)
    combo = Gtk::ComboBoxText.new
    combo.append_text('auto')
    combo.append_text('password')
    combo.append_text('vxace-seed')
    combo.append_text('password-file')
    combo.active = 0
    entry = Gtk::Entry.new
    entry.placeholder_text = 'hex32 key, 8-hex seed or key-list path (per mode)'
    key_label = Gtk::Label.new('Key:')
    key_label.margin_start = 6
    box.pack_start(key_label, expand: false, fill: false, padding: 0)
    box.pack_start(combo, expand: false, fill: false, padding: 0)
    box.pack_start(entry, expand: false, fill: false, padding: 0)
    [box, combo, entry]
  end

  def key_args
    return [] if @key_entry.text.to_s.empty?

    case @key_type.active_text
    when 'password' then ['--password', @key_entry.text]
    when 'vxace-seed' then ['--vxace-seed', @key_entry.text]
    when 'password-file' then ['--password-file', @key_entry.text]
    else []
    end
  end

  # Command line for the log, with secret key material masked. Paths given via
  # --password-file are kept visible — they are not secrets. Plain join (not
  # shelljoin): the subprocess is spawned from the argument array, and
  # shelljoin would mangle Windows backslash paths; this line is for humans.
  def self.redact_join(args)
    masked = []
    hide_next = false
    args.each do |a|
      if hide_next
        masked << 'REDACTED'
        hide_next = false
      elsif %w[--password --vxace-seed].include?(a)
        masked << a
        hide_next = true
      else
        masked << a
      end
    end
    masked.join(' ')
  end

  # ---- logging / progress (always on the GTK main thread) ------------------
  def log(text)
    GLib::Idle.add do
      @log_buf.insert(@log_buf.end_iter, text.to_s + "\n")
      false
    end
  end

  def set_status(text)
    GLib::Idle.add do
      @status.text = text.to_s
      false
    end
  end

  # ---- bulk decrypt --------------------------------------------------------
  def run_bulk
    return if @running

    game = @game_entry.filename
    out = @out_entry.filename
    if game.nil? || game.empty?
      log('[!] Select the source game folder.')
      return
    end
    if out.nil? || out.empty?
      log('[!] Select the output folder.')
      return
    end
    if File.expand_path(out) == File.expand_path(game)
      log('[!] Output folder must differ from the source game folder ' \
          '(the tool mirrors the tree and would overwrite the originals).')
      return
    end
    if File.directory?(out) && !Dir.empty?(out) && !confirm_nonempty_output(out)
      log('[!] Cancelled — output folder is not empty.')
      return
    end

    args = [OCAML_EXE]
    args << '--assets-only' if @assets_only.active?
    args << '--dry-run' if @dry_run.active?
    args += ['--log-format', 'json', '--report-format', 'json', game, out]
    args += key_args
    run_decrypt(args, "Decrypting game → #{out}")
  end

  # ---- point decrypt -------------------------------------------------------
  def refresh_list
    game = @p_game_entry.filename
    if game.nil? || game.empty?
      log('[!] Select a game folder to build the list.')
      return
    end
    @files = []
    begin
      Find.find(game) do |path|
        next unless File.file?(path)

        rel = Pathname.new(path).relative_path_from(Pathname.new(game)).to_s.tr('/', '\\')
        ext = File.extname(rel).downcase
        status = if ENCRYPTED_ASSET_EXT.key?(ext)
                   'encrypted (asset)'
                 elsif ARCHIVE_EXT.include?(ext)
                   'archive (RGSS)'
                 else
                   ''
                 end
        @files << [rel, File.size(path).to_s, status]
      end
    rescue => ex
      log("[!] Folder scan error: #{ex.message}")
    end
    populate_tree(@filter.text.to_s)
    log("List refreshed: #{@files.size} files in #{game}")
  end

  def populate_tree(filter)
    @store.clear
    pat = filter.to_s.downcase
    (@files || []).each do |rel, size, status|
      next unless pat.empty? || rel.downcase.include?(pat)

      it = @store.append
      it[0] = rel
      it[1] = size
      it[2] = status
    end
  end

  def point_decrypt
    return if @running
    return unless OCAML_EXE

    game = @p_game_entry.filename
    unless game && !game.empty?
      log('[!] Select the game folder.')
      return
    end
    unless @selected_rel
      log('[!] Select a file in the list.')
      return
    end
    ext = File.extname(@selected_rel).downcase
    if ARCHIVE_EXT.include?(ext)
      log('[!] For archives (.rgssad/.rgss2a/.rgss3a) use the "Whole game" mode.')
      return
    end

    temp_out = File.join(Dir.tmpdir, "rpgm_gui_#{Process.pid}")
    FileUtils.rm_rf(temp_out)
    args = [OCAML_EXE, '--assets-only', '--log-format', 'json',
            '--report-format', 'json', game, temp_out] + key_args

    run_decrypt(args, "Single-file decryption (temp folder)") do |ok|
      if ok
        out_rel =     RpgmDecryptCore.map_output_rel(@selected_rel)
        src = File.join(temp_out, out_rel.tr('/', '\\'))
        unless File.exist?(src)
          log("[!] Decrypted file not found: #{out_rel}")
          FileUtils.rm_rf(temp_out)
          next
        end

        begin
          cache_dir = File.join(EXE_DIR, 'decrypted_cache')
          dest = File.join(cache_dir, out_rel.tr('/', '\\'))
          FileUtils.mkdir_p(File.dirname(dest))
          FileUtils.cp(src, dest)
          @point_cache = {
            decrypted: dest,
            original: File.join(game, @selected_rel.tr('/', '\\')),
            rel: @selected_rel
          }
          GLib::Idle.add do
            @return_btn.sensitive = true
            false
          end
          log("Decrypted and saved: #{dest}")
          set_status('one file decrypted — you can restore it in place')
        rescue StandardError => e
          log("[!] Could not cache the decrypted file: #{e.class}: #{e.message}")
          set_status('failed to cache the decrypted file')
        ensure
          FileUtils.rm_rf(temp_out)
        end
      else
        FileUtils.rm_rf(temp_out)
        if @cancel_requested
          log('[!] Single-file decryption cancelled.')
        else
          log('[!] Single-file decryption failed (see log above).')
        end
      end
    end
  end

  def return_to_place
    return unless @point_cache

    dec = @point_cache[:decrypted]
    orig = @point_cache[:original]
    unless dec && File.exist?(dec)
      log('[!] No decrypted file yet (decrypt first).')
      return
    end
    rel = @point_cache[:rel]
    out_rel = RpgmDecryptCore.map_output_rel(rel)
    game = File.dirname(orig)
    target = File.join(game, out_rel.tr('/', '\\'))

    begin
      backup = orig + '.bak'
      unless File.exist?(backup)
        FileUtils.cp(orig, backup)
        log("Original backed up: #{backup}")
      end
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(dec, target)
      FileUtils.rm_f(orig) if out_rel.tr('/', '\\') != rel.tr('/', '\\')
      log("Restored (decrypted file) → #{target}")
      set_status('file replaced with the decrypted one; original kept as .bak')
    rescue StandardError => e
      log("[!] Restore failed: #{e.class}: #{e.message}")
      set_status('restore failed')
    end
  end

  def open_path(path)
    return unless path && File.exist?(path)

    target = File.directory?(path) ? path : File.dirname(path)
    # Fire-and-forget (see GateWindow#open_url): a blocking system() here
    # would freeze the GTK main loop while Explorer spins up.
    pid = Process.spawn('cmd', '/c', 'start', '', target)
    Process.detach(pid)
  rescue StandardError => e
    warn "[rpgm-gui] folder open failed: #{e.class}: #{e.message}"
  end

  # Terminate the running decrypter (shared Stop button; both tabs route
  # through run_decrypt, so one handler covers bulk and point modes).
  def request_cancel
    return unless @running

    @cancel_requested = true
    log('[!] Stop requested — terminating the decrypter...')
    set_status('stopping…')
  end

  # Dump the log text buffer to a user-chosen file.
  def save_log
    dlg = Gtk::FileChooserDialog.new(title: 'Save log', parent: @window, action: :save,
                                     buttons: [['Save', Gtk::ResponseType::ACCEPT],
                                               ['Cancel', Gtk::ResponseType::CANCEL]])
    dlg.current_name = 'rpgm-gui-log.txt'
    if dlg.run == Gtk::ResponseType::ACCEPT
      begin
        File.write(dlg.filename, @log_buf.text)
        log("Log saved: #{dlg.filename}")
      rescue StandardError => e
        log("[!] Log save failed: #{e.class}: #{e.message}")
      end
    end
    dlg.destroy
  end

  # Modal guard against silently merging into a non-empty output folder.
  def confirm_nonempty_output(out)
    return true unless File.directory?(out) && !Dir.empty?(out)

    dlg = Gtk::MessageDialog.new(parent: @window, flags: Gtk::DialogFlags::MODAL,
                                 type: Gtk::MessageType::QUESTION,
                                 buttons: Gtk::ButtonsType::YES_NO,
                                 message: "Output folder is not empty:\n#{out}\n\n" \
                                          'Continue anyway (existing files may be overwritten)?')
    resp = dlg.run
    dlg.destroy
    resp == Gtk::ResponseType::YES
  end

  # ---- subprocess runner --------------------------------------------------
  # Runs the OCaml decrypter in a background thread so the GTK main loop stays
  # responsive. The actual subprocess + NDJSON parsing lives in
  # RpgmDecryptCore.run_decrypt; UI updates are marshalled back via GLib::Idle.add.
  # Calls the optional on_done block (on the main thread) with the success flag
  # (true when exit code is 0 or 5).
  def run_decrypt(args, label, &on_done)
    return if @running

    @running = true
    @cancel_requested = false
    @stop_btn.sensitive = true
    @state = { total: 0, done: 0, summary: nil }
    log("== #{label}")
    log(RpgmGui.redact_join(args))

    Thread.new do
      result = RpgmDecryptCore.run_decrypt(args, cancel: -> { @cancel_requested }) do |ev|
        GLib::Idle.add { apply_event(ev) }
      end
      GLib::Idle.add do
        if result[:cancelled]
          log('[!] Cancelled by user.')
          set_status('cancelled')
        else
          unless result[:summary].to_s.strip.empty?
            begin
              s = JSON.parse(result[:summary])
              @state[:summary] = s
              log("SUMMARY: scanned=#{s['scanned']} decrypted=#{s['decrypted']} " \
                  "failed=#{s['failed']} key=#{s['key_source']}")
            rescue JSON::ParserError
              log("SUMMARY: #{result[:summary].strip}")
            end
          end
          log("[ERROR] failed to start the decrypter: #{result[:error]}") if result[:error]
          set_status('done')
        end
        # on_done runs while @cancel_requested still reflects the finished run,
        # so callers can tell "cancelled" from "failed".
        on_done.call(result[:success]) if on_done
        @stop_btn.sensitive = false
        @cancel_requested = false
        @running = false
        false
      end
    end
  end

  def apply_event(ev)
    frac = RpgmDecryptCore.apply_progress(@state, ev)
    if frac
      @progress.fraction = [[frac, 0.0].max, 1.0].min
      @progress.text = "#{@state[:done]}/#{@state[:total]}"
    else
      @progress.pulse
    end

    line = RpgmDecryptCore.human_line(ev)
    @log_buf.insert(@log_buf.end_iter, line + "\n") if line
    false
  end
end

# ---------------------------------------------------------------------------
# First-launch star gate window (see star_gate.rb for the network flow).
# Port of the RenpyEx gate: sign in via the GitHub device flow, star the
# repository, unlock — and never ask again on this machine (config.json).
class GateWindow
  def initialize
    @unlocked = false
    @quit = false
    @token = nil
    @browser_opened = false

    @window = Gtk::Window.new('rpgm decrypt — unlock')
    @window.resizable = false
    @window.set_default_size(560, 440)
    @window.window_position = :center
    # ONE Gtk.main for the whole app (started by the bootstrap at the bottom
    # of this file). When the gate closes unlocked, it hands over to the main
    # window INSIDE the same loop — creating a window after Gtk.main_quit
    # silently kills the packed exe.
    @window.signal_connect('destroy') do
      @quit = true
      GLib::Idle.add do
        if @unlocked
          begin
            RpgmGui.new
          rescue StandardError => e
            warn "[rpgm-gui] main window failed after unlock: #{e.class}: #{e.message}"
            Gtk.main_quit
          end
        else
          Gtk.main_quit
        end
        false
      end
    end
    icon_file = [File.join(EXE_DIR, 'rpgm-decrypt.png'),
                 File.join(EXE_DIR, 'rpgm-decrypt.ico')].find { |p| File.exist?(p) }
    if icon_file
      begin
        @window.icon = GdkPixbuf::Pixbuf.new(file: icon_file)
      rescue StandardError => e
        warn "[rpgm-gui] gate icon load failed: #{e.class}: #{e.message}"
      end
    end

    @content = Gtk::Box.new(:vertical, 10)
    @content.style_context.add_class('app-frame')
    @content.margin = 14
    @window.add(@content)

    show_intro
    @window.show_all
  end

  def unlocked?
    @unlocked
  end

  private

  def clear
    @content.children.each { |c| @content.remove(c) }
  end

  def pack(widget)
    @content.pack_start(widget, expand: false, fill: false, padding: 0)
  end

  def title_label(text)
    l = Gtk::Label.new
    l.markup = text
    l.style_context.add_class('app-title')
    l.halign = :center
    l
  end

  def note_label(text)
    l = Gtk::Label.new(text)
    l.halign = :center
    l.justify = :center
    l.wrap = true
    l
  end

  def open_url(url)
    # Never system() here: it runs on the GTK main thread and spawning the
    # default browser can stall the message loop for seconds ("not
    # responding"). Fire-and-forget instead.
    pid = Process.spawn('cmd', '/c', 'start', '', url)
    Process.detach(pid)
  rescue StandardError => e
    warn "[rpgm-gui] browser open failed: #{e.class}: #{e.message}"
  end

  # GLib has no markup_escape_text in ruby-gnome 4.x — escape Pango markup by hand.
  def xml_escape(s)
    s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end

  def show_intro
    clear
    pack(title_label('★ Support rpgm-decrypt ★'))
    pack(note_label("rpgm-decrypt is free and open source.\n" \
                    'To unlock the GUI, sign in with GitHub and star ★ the project.'))
    pack(note_label('Just press the button — it guides you through 3 easy steps. ' \
                    'No password is entered in this app.'))
    btn = Gtk::Button.new(label: 'Sign in with GitHub  ★')
    btn.signal_connect('clicked') { start_flow }
    pack(btn)
    @content.show_all
  end

  def start_flow
    # No daemon threads in Ruby: the worker dies with the main thread on exit.
    Thread.new do
      RpgmStarGate.run_device_flow(method(:on_gate_event), stop_check: -> { @quit })
    end
  end

  # Worker thread → main thread marshalling (same pattern as run_decrypt).
  def on_gate_event(kind, *args)
    return if @quit

    GLib::Idle.add do
      handle_event(kind, args) unless @quit
      false
    end
  end

  def handle_event(kind, args)
    case kind
    when :device_code then show_device(args[0], args[1])
    when :starred
      @unlocked = true
      RpgmStarGate.save_unlock(EXE_DIR, args[0])
      show_done(args[0])
    when :not_starred
      @login = args[0]
      @token = args[1]
      show_not_starred
    when :denied then show_error(args.first)
    when :failed then show_error(args.first)
    end
  rescue StandardError => e
    # Never leave a blank window: any stage-render failure degrades to the
    # error screen with a Retry button.
    begin
      show_error("#{e.class}: #{e.message}")
    rescue StandardError
      warn "[rpgm-gui] gate event error: #{e.class}: #{e.message}"
    end
  end

  def show_device(user_code, verification_uri)
    clear
    pack(title_label('★ Support rpgm-decrypt ★'))

    pack(note_label('STEP 1 of 3 — sign in to GitHub. The page should have opened ' \
                    "in your browser; if not, open it manually:\n#{verification_uri}"))
    open_btn = Gtk::Button.new(label: 'Open GitHub sign-in page  ⤴')
    open_btn.signal_connect('clicked') { open_url(verification_uri) }
    pack(open_btn)

    pack(note_label('STEP 2 of 3 — copy this code, paste it on that page and press Continue:'))
    code = Gtk::Label.new
    code.markup = "<span size='24000' face='monospace'>#{xml_escape(user_code)}</span>"
    code.selectable = true
    code.halign = :center
    pack(code)

    pack(note_label('STEP 3 of 3 — waiting for authorization…'))
    @content.show_all

    unless @browser_opened
      @browser_opened = true
      open_url(verification_uri)
    end
  end

  def show_not_starred
    clear
    pack(title_label('Almost there, ' + xml_escape(@login.to_s) + '!'))
    pack(note_label('Your account is signed in, but the repository is not starred yet. ' \
                    'Press the button below, then click the ★ Star button on GitHub:'))
    star_btn = Gtk::Button.new(label: '★ Star on GitHub')
    star_btn.signal_connect('clicked') { open_url(RpgmStarGate::REPO_URL) }
    pack(star_btn)
    check_btn = Gtk::Button.new(label: 'Check again')
    check_btn.signal_connect('clicked') do
      Thread.new do
        RpgmStarGate.recheck_star(@token, method(:on_gate_event))
      end
    end
    pack(check_btn)
    pack(note_label('(starred but the check says no? GitHub caches for a moment — ' \
                    'press Check again in a few seconds)'))
    @content.show_all
  end

  def show_done(login)
    clear
    pack(title_label('★ Unlocked — thank you! ★'))
    pack(note_label("Starred by #{login}.\n" \
                    'rpgm-decrypt GUI will not ask again on this computer.'))
    go = Gtk::Button.new(label: 'Start decrypting')
    go.signal_connect('clicked') { @window.destroy }
    pack(go)
    @content.show_all
  end

  def show_error(message)
    clear
    pack(title_label('Unlock problem'))
    pack(note_label(message.to_s))
    pack(note_label("(offline? the gate needs internet on the first run only —\n" \
                    'already activated computers work offline forever)'))
    retry_btn = Gtk::Button.new(label: 'Retry')
    retry_btn.signal_connect('clicked') { show_intro }
    pack(retry_btn)
    @content.show_all
  end
end

# Launch the GUI. Skip during OCRA's build-time "training" run (set by
# build_windows.ps1) so the packager doesn't block on Gtk.main.
#
# Single main loop for the whole app: if this machine is already unlocked the
# main window opens directly; otherwise the star gate runs first and hands
# over to the main window (inside the same loop) once the signed-in GitHub
# account is verified to star the repo.
if ENV['RPGM_GUI_BUILD'].nil?
  Gtk.init
  RpgmGui.apply_style
  if RpgmStarGate.load_unlock(EXE_DIR)
    RpgmGui.new
  else
    GateWindow.new
  end
  Gtk.main
end
