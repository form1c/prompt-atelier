# frozen_string_literal: true

require_relative '../../test_helper'
require 'open3'
require 'zlib'
require 'archive'

# The two archive formats of 18.8 (NFA-20, BT-08).
#
# Read back **without** `tar` and `unzip`, by parsing the bytes here. Two
# reasons: the suite has to run on a machine that has neither, and a reader
# written from the specification is an independent second opinion — if writer
# and reader shared a mistake, a round trip through one code base would agree
# with itself and prove nothing. The two cases at the end hand the archives to
# the real tools where they exist, because in the end those are what unpacks
# them at somebody else's desk.
class ArchiveTest < PromptAtelier::TestCase
  A = PromptAtelier::Archive

  # A fixed moment, so that every expectation about timestamps is a value and
  # not "whenever this ran".
  MOMENT = Time.utc(2026, 8, 4, 12, 0, 0)

  def setup
    super
    @source = File.join(install_dir('archive'), 'tree')
    FileUtils.mkdir_p(@source)
  end

  # --- what ends up in an archive -------------------------------------------

  def test_every_file_and_every_directory_travels_including_the_empty_ones
    write('app/app.rb', 'x')
    FileUtils.mkdir_p(File.join(@source, 'data/backups'))

    names = tar_entries(tar).map { |entry| entry[:name] }

    assert_includes names, 'pkg/app/app.rb'
    assert_includes names, 'pkg/data/'
    assert_includes names, 'pkg/data/backups/',
                    'without directory entries an empty data/ would not exist after unpacking (18.2)'
  end

  # `scripts/install.sh` has to stay runnable after unpacking. It is the first
  # thing somebody types, and a permission error there reads like a broken
  # package.
  def test_the_executable_bit_survives_both_formats
    write('scripts/install.sh', "#!/bin/sh\n", mode: 0o755)
    write('app/app.rb', 'x', mode: 0o644)

    tar_modes = tar_entries(tar).to_h { |entry| [entry[:name], entry[:mode]] }
    zip_modes = zip_entries(zip).to_h { |entry| [entry[:name], entry[:mode]] }

    assert_equal 0o755, tar_modes['pkg/scripts/install.sh']
    assert_equal 0o644, tar_modes['pkg/app/app.rb']
    assert_equal 0o755, zip_modes['pkg/scripts/install.sh']
    assert_equal 0o644, zip_modes['pkg/app/app.rb']
  end

  # The development tree links `backend/vendor` for the test suites. A link
  # points at a path the target machine does not have, so it must never reach
  # an archive — and the failure would be a `vendor` that looks present and
  # resolves to nothing.
  def test_a_symbolic_link_is_left_behind
    write('app/app.rb', 'x')
    FileUtils.ln_s('/somewhere/else', File.join(@source, 'app', 'vendor'))

    names = tar_entries(tar).map { |entry| entry[:name] }

    refute_includes names, 'pkg/app/vendor'
    assert_includes names, 'pkg/app/app.rb', 'and the rest still travels'
  end

  # --- the same source, the same bytes (NFA-20) -----------------------------

  # The claim of 18.8, at its strongest: not "the same file list" but the same
  # archive. Everything that could differ between two runs — the order the file
  # system hands out names, the modification times, the owner, the umask — is
  # decided by the writer.
  def test_two_writes_of_one_tree_are_byte_identical
    write('app/app.rb', 'x')
    write('scripts/install.sh', "#!/bin/sh\n", mode: 0o755)
    FileUtils.mkdir_p(File.join(@source, 'data'))

    first_tar  = tar(into: 'first.tar.gz')
    first_zip  = zip(into: 'first.zip')
    # Touched in between: the archives must not notice.
    FileUtils.touch(File.join(@source, 'app', 'app.rb'), mtime: Time.now + 3600)
    second_tar = tar(into: 'second.tar.gz')
    second_zip = zip(into: 'second.zip')

    assert_equal File.binread(first_tar), File.binread(second_tar)
    assert_equal File.binread(first_zip), File.binread(second_zip)
  end

  # The counter-check to the case above, and without it that one would also
  # pass over a writer that put a constant into every archive.
  def test_a_changed_file_changes_the_archive
    write('app/app.rb', 'x')
    before = File.binread(tar(into: 'before.tar.gz'))

    write('app/app.rb', 'y')

    refute_equal before, File.binread(tar(into: 'after.tar.gz'))
  end

  # Both halves of reproducibility live here: the order does not come from the
  # file system, and the mode does not come from the umask of whoever built.
  def test_the_order_is_the_names_and_the_mode_is_normalised
    write('zeta.txt', 'z')
    write('alpha.txt', 'a', mode: 0o640)
    FileUtils.mkdir_p(File.join(@source, 'beta'))

    entries = A.entries(@source)

    assert_equal %w[alpha.txt beta/ zeta.txt], entries.map { |entry| entry[:name] }
    assert_equal 0o644, entries.find { |entry| entry[:name] == 'alpha.txt' }[:mode],
                 'a build under a different umask has to produce the same archive'
  end

  def test_the_timestamp_is_the_one_it_was_given
    write('app/app.rb', 'x')

    entry = tar_entries(tar).find { |item| item[:name] == 'pkg/app/app.rb' }

    assert_equal MOMENT.to_i, entry[:mtime]
  end

  # --- long paths ------------------------------------------------------------

  # A vendored gem tree gets deep: the longest path of the delivered bundle is
  # over 140 characters, and tar keeps only 100 in the name field. ustar splits
  # the rest into a prefix — which is the one part of the format that is easy
  # to leave out and only fails on the deepest file of a real package.
  def test_a_path_too_long_for_the_name_field_is_split_and_comes_back_whole
    deep = "app/vendor/bundle/ruby/3.3.0/gems/sequel-5.106.0/lib/sequel/plugins/#{'x' * 40}.rb"
    write(deep, 'x')

    names = tar_entries(tar).map { |entry| entry[:name] }

    assert_operator "pkg/#{deep}".length, :>, 100, 'the case only means something above the limit'
    assert_includes names, "pkg/#{deep}"
  end

  # And where it cannot be split, it says so instead of writing a header with a
  # silently shortened name.
  def test_a_name_that_cannot_be_split_is_refused_out_loud
    write("#{'n' * 120}.rb", 'x')

    assert_raises(PromptAtelier::Archive::Error) { tar }
  end

  # --- what the real tools make of it ---------------------------------------
  #
  # The parsers above follow the specification; these two ask the programs that
  # will actually unpack the delivery. They are skipped where the tool is
  # missing, and the assertion above them is the one that always runs.

  def test_gnu_tar_reads_the_archive
    skip 'no tar on this machine' unless available?('tar')

    write('app/app.rb', 'content')
    output, status = Open3.capture2e('tar', '-tzf', tar)

    assert_predicate status, :success?, output
    assert_includes output, 'pkg/app/app.rb'
  end

  # More than one reader is tried, because `unzip` is missing on a surprising
  # number of Linux installations — this one included. Asking only for it would
  # have turned the one case that hands a zip file to an independent
  # implementation into a permanent skip, and a skipped case is not a passed
  # one (test concept 3.4, rule 9).
  def test_a_real_zip_reader_accepts_the_archive
    reader = zip_reader
    skip 'no zip reader on this machine' if reader.nil?

    write('app/app.rb', 'content')
    output, status = Open3.capture2e(*reader, zip)

    assert_predicate status, :success?, output
  end

  def zip_reader
    return %w[unzip -t] if available?('unzip')
    return %w[python3 -m zipfile -t] if available?('python3')
    return %w[7z t] if available?('7z')

    nil
  end

  private

  def write(name, contents, mode: 0o644)
    path = File.join(@source, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    File.chmod(mode, path)
    path
  end

  def tar(into: 'package.tar.gz')
    A.tar_gz(root: @source, base: 'pkg', into: File.join(File.dirname(@source), into), mtime: MOMENT)
  end

  def zip(into: 'package.zip')
    A.zip(root: @source, base: 'pkg', into: File.join(File.dirname(@source), into), mtime: MOMENT)
  end

  def available?(program)
    system(program, '--version', out: File::NULL, err: File::NULL) ? true : false
  rescue Errno::ENOENT
    false
  end

  # --- readers written from the specification -------------------------------

  def tar_entries(path)
    raw = Zlib::GzipReader.open(path) { |gz| gz.read.b }
    entries = []
    offset = 0

    while offset + 512 <= raw.bytesize
      header = raw[offset, 512]
      break if header.each_byte.all?(&:zero?)

      entries << tar_entry(header)
      offset += 512 + ((entries.last[:size] + 511) / 512) * 512
    end
    entries
  end

  def tar_entry(header)
    name   = field(header, 0, 100)
    prefix = field(header, 345, 155)
    size   = field(header, 124, 12).to_i(8)

    # The checksum is what GNU tar rejects an archive on, so it is checked here
    # rather than left to the two cases that need a program on the machine.
    assert_equal expected_checksum(header), field(header, 148, 8).to_i(8),
                 'a header with a wrong checksum is refused by every real tar'

    { name: prefix.empty? ? name : "#{prefix}/#{name}", size: size,
      mode: field(header, 100, 8).to_i(8), mtime: field(header, 136, 12).to_i(8),
      type: header[156] }
  end

  def expected_checksum(header)
    blanked = header.dup
    blanked[148, 8] = ' ' * 8
    blanked.bytes.sum
  end

  def field(header, offset, length) = header[offset, length].split("\0").first.to_s.strip

  # The central directory is the authority in a zip file; a reader that only
  # looked at the local headers would miss a wrong offset.
  def zip_entries(path)
    raw = File.binread(path)
    start = raw.rindex([0x06054b50].pack('V'))
    # Total entries, size and offset of the central directory sit ten bytes
    # into the end record, after the two disk numbers and the per-disk count.
    count, _size, offset = raw[start + 10, 10].unpack('vVV')

    Array.new(count).each_with_object([]) do |_, entries|
      signature, _made, _needed, _flags, _method, _time, _date, _crc, _csize, _usize,
        name_length, extra_length, comment_length, _disk, _internal, external =
        raw[offset, 46].unpack('VvvvvvvVVVvvvvvV')

      raise "not a central directory record at #{offset}" unless signature == 0x02014b50

      entries << { name: raw[offset + 46, name_length], mode: (external >> 16) & 0o7777 }
      offset += 46 + name_length + extra_length + comment_length
    end
  end
end
