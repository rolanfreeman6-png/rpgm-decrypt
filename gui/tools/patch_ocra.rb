# gui/tools/patch_ocra.rb — make OCRA 1.3.11 build on Ruby >= 3.3.12.
#
# Ruby 3.3.12 lists "fiber.so" in $LOADED_FEATURES although no such file
# exists anywhere (the feature is built into the interpreter, like the
# enumerator.so / rational.so / complex.so / thread.rb / ruby2_keywords.rb
# phantoms of older rubies that OCRA already knows about). OCRA resolves the
# unqualified feature against its source root, so a pristine gem tries to
# File.open "<script dir>/fiber.so", gets Errno::ENOENT inside
# OcraBuilder#createfile and — "fiber.so" not being on its IGNORE_MODULE_NAMES
# rescue list — dies mid-build with exit 1, after "Adding user-supplied source
# files" and with no ERROR: line.
#
# Guarding createfile with File.exist?(src) turns every phantom feature into a
# no-op: the same effect the upstream ignore list provides for the older
# phantom names, without forking the gem. The patch is byte-exact (binary
# read/write, CRLF preserved) and idempotent: an already-patched gem is left
# untouched, and an OCRA whose layout no longer matches the anchor aborts
# loudly instead of being mis-patched.
#
# Called by build_windows.ps1 before invoking OCRA.

require 'rubygems'

guard = 'return unless File.exist?(src)'
spec = Gem::Specification.find_by_name('ocra')
bin = File.join(spec.full_gem_path, 'bin', 'ocra')
src = File.binread(bin)

if src.include?(guard)
  puts "ocra #{spec.version}: createfile guard already present, nothing to do"
  exit 0
end

patched = src.sub(/( *)ensuremkdir\(tgt\.dirname\)(\r?\n)( *)str = File\.open\(src/) do
  ind = Regexp.last_match(1)
  nl = Regexp.last_match(2)
  "#{ind}ensuremkdir(tgt.dirname)#{nl}#{ind}#{guard}#{nl}#{Regexp.last_match(3)}str = File.open(src"
end

# ensuremkdir(tgt.dirname) also occurs inside ensuremkdir itself; only the
# createfile occurrence is followed by "str = File.open(src", so a nil here
# means the gem layout changed and this patch must be revisited.
abort "patch_ocra: anchor not found in #{bin} (ocra #{spec.version} layout changed?)" if patched == src

File.binwrite(bin, patched)
puts "ocra #{spec.version}: patched createfile guard into #{bin}"
