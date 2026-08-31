# frozen_string_literal: true

# scripts/lib/archive.rb — the two archive formats of 18.8, written here
# rather than handed to `tar` and `zip`.
#
# **Reproducibility is a property of the writer, not of the sources** (NFA-20).
# The system tools put the modification time of every file into the archive and
# take the entries in whatever order the file system hands out names. Two
# builds an hour apart then differ in every single entry, and "the same source
# produces the same package" could only ever be checked after unpacking. Here
# the entries are sorted, all timestamps come from one value, and owner and
# mode are normalised — so two builds of one source are **byte-identical** and
# a single checksum settles the question.
#
# The second reason is availability. `zip` is absent on most Linux servers, and
# `tar --sort=name` is GNU-only — neither is on a Windows machine at all. A
# build step that only works on the machine it was written on is not a build
# step.
#
# Both writers emit **directory entries**, including empty ones. Without them
# `data/`, `data/backups/` and `data/logs/` would not exist after unpacking,
# and 18.2 asks for a directory structure that is complete from that moment.

require 'zlib'

module PromptAtelier
  # Deliberately not `extend Script`: this module writes bytes and says
  # nothing, so it needs neither the locale files nor the installation paths.
  # It is the one part of the build a test can exercise with three files in a
  # temporary directory.
  module Archive
    class Error < StandardError; end

    BLOCK = 512

    # tar cannot carry a path of any length. ustar splits it into a prefix of
    # up to 155 bytes and a name of up to 100 — 255 together, which the deepest
    # path of a vendored gem tree comes close to but stays under.
    NAME_MAX   = 100
    PREFIX_MAX = 155

    module_function

    # Every entry of +root+, directories included, in a fixed order.
    #
    # Sorted by the path, so the result does not depend on the file system.
    # Directories sort before their contents because their name ends in `/`,
    # and `/` comes before every character that may start a file name.
    def entries(root)
      root = File.expand_path(root)

      Dir.glob('**/*', File::FNM_DOTMATCH, base: root)
         .reject { |name| %w[. ..].include?(File.basename(name)) }
         .map    { |name| entry(root, name) }
         .compact
         .sort_by { |item| item[:name] }
    end

    def entry(root, name)
      path = File.join(root, name)
      stat = File.lstat(path)
      # A symbolic link in a delivery package points at something the target
      # machine does not have. The development tree links `vendor` for the test
      # suites, and that link must never end up in an archive.
      return nil if stat.symlink?

      { name: stat.directory? ? "#{name}/" : name, path: path,
        directory: stat.directory?, size: stat.directory? ? 0 : stat.size,
        mode: normalised_mode(stat) }
    end

    # Two modes, not the ones this machine happens to have. A build under a
    # different umask would otherwise produce a different archive from the same
    # source — and the executable bit is the one distinction that matters,
    # because `scripts/install.sh` has to stay runnable after unpacking.
    def normalised_mode(stat)
      return 0o755 if stat.directory? || (stat.mode & 0o111).positive?

      0o644
    end

    # --- tar.gz ---------------------------------------------------------------

    def tar_gz(root:, base:, into:, mtime:)
      File.open(into, 'wb') do |file|
        writer = Zlib::GzipWriter.new(file, Zlib::BEST_COMPRESSION)
        # The gzip header carries a timestamp of its own. Left alone it would
        # be "now", and two builds of one source would differ in eight bytes
        # nobody thinks to look at.
        writer.mtime = mtime
        begin
          write_tar(writer, entries(root), base, mtime)
        ensure
          writer.close
        end
      end
      into
    end

    def write_tar(io, entries, base, mtime)
      entries.each do |item|
        io.write(tar_header("#{base}/#{item[:name]}", item, mtime))
        next if item[:directory]

        write_padded(io, item[:path], item[:size])
      end
      # Two empty blocks close a tar file. Without them GNU tar reads to the
      # end and reports "unexpected EOF" on an archive that is complete.
      io.write("\0" * (BLOCK * 2))
    end

    def write_padded(io, path, size)
      File.open(path, 'rb') { |source| IO.copy_stream(source, io) }
      remainder = size % BLOCK
      io.write("\0" * (BLOCK - remainder)) if remainder.positive?
    end

    def tar_header(name, item, mtime)
      prefix, name = split_name(name)

      # Assembled as bytes from the first character. `header[148, 8] = …` below
      # counts **characters**, so a single non-ASCII byte anywhere in the name
      # would put the checksum somewhere other than in the checksum field.
      header = [
        pad(name, 100), octal(item[:mode], 7), octal(0, 7), octal(0, 7),
        octal(item[:size], 11), octal(mtime.to_i, 11),
        ' ' * 8,                                    # checksum, filled in below
        item[:directory] ? '5' : '0', pad('', 100), # type, link target
        "ustar\0", '00', pad('', 32), pad('', 32),  # magic, version, user, group
        octal(0, 7), octal(0, 7), pad(prefix, 155)  # device numbers, prefix
      ].join.b.ljust(BLOCK, "\0".b)

      # The checksum is the sum of every byte with the checksum field read as
      # spaces, which is why it was written as spaces above. Summed over the
      # bytes rather than with String#sum: that one wraps at 16 bits by
      # default, and a full header exceeds that.
      header[148, 8] = "#{format('%06o', header.bytes.sum)}\0 ".b
      header
    end

    # ustar keeps the last component in `name` and everything before it in
    # `prefix`. The longest prefix that fits is chosen, because that leaves the
    # most room for the file name — the part that cannot be split further.
    def split_name(name)
      return ['', name] if name.bytesize <= NAME_MAX

      cut = name.rindex('/', PREFIX_MAX)
      tail = cut ? name[(cut + 1)..] : name
      raise Error, "path too long for a tar archive: #{name}" if cut.nil? || tail.bytesize > NAME_MAX

      [name[0...cut], tail]
    end

    def octal(value, digits) = format("%0#{digits}o", value) + "\0"

    def pad(text, width)
      raise Error, "value too long for a tar header: #{text}" if text.bytesize > width

      text.b.ljust(width, "\0".b)
    end

    # --- zip ------------------------------------------------------------------
    #
    # Written by hand for the same two reasons. The local headers carry the
    # sizes up front rather than through a data descriptor, so the archive can
    # be read by tools that do not seek — and because a descriptor would need
    # the flag bit that some Windows versions still handle badly.

    LOCAL_SIGNATURE   = 0x04034b50
    CENTRAL_SIGNATURE = 0x02014b50
    END_SIGNATURE     = 0x06054b50

    # Made by Unix (3), zip specification 3.0. This is what makes a zip reader
    # honour the permission bits in the external attributes — without it the
    # `.sh` launchers arrive without their executable bit.
    MADE_BY = (3 << 8) | 30
    NEEDED  = 20

    def zip(root:, base:, into:, mtime:)
      records = []

      File.open(into, 'wb') do |io|
        entries(root).each do |item|
          records << zip_entry(io, "#{base}/#{item[:name]}", item, mtime)
        end
        write_central_directory(io, records)
      end
      into
    end

    def zip_entry(io, name, item, mtime)
      offset = io.pos
      data, crc, size = zip_payload(item)
      stored = item[:directory] ? 0 : 8

      io.write([LOCAL_SIGNATURE, NEEDED, 0, stored, dos_time(mtime), dos_date(mtime),
                crc, data.bytesize, size, name.bytesize, 0].pack('VvvvvvVVVvv'))
      io.write(name)
      io.write(data)

      { name: name, method: stored, crc: crc, compressed: data.bytesize,
        size: size, offset: offset, mode: item[:mode], directory: item[:directory],
        time: dos_time(mtime), date: dos_date(mtime) }
    end

    def zip_payload(item)
      return ['', 0, 0] if item[:directory]

      content = File.binread(item[:path])
      # Raw deflate: the two-byte zlib header and the trailing checksum are not
      # part of a zip entry. `-MAX_WBITS` is how Zlib is asked for that.
      deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION, -Zlib::MAX_WBITS)
      [deflater.deflate(content, Zlib::FINISH).tap { deflater.close },
       Zlib.crc32(content), content.bytesize]
    end

    def write_central_directory(io, records)
      start = io.pos

      records.each { |record| write_central_record(io, record) }

      io.write([END_SIGNATURE, 0, 0, records.size, records.size,
                io.pos - start, start, 0].pack('VvvvvVVv'))
    end

    def write_central_record(io, record)
      io.write([CENTRAL_SIGNATURE, MADE_BY, NEEDED, 0, record[:method],
                record[:time], record[:date], record[:crc], record[:compressed],
                record[:size], record[:name].bytesize, 0, 0, 0, 0,
                external_attributes(record), record[:offset]].pack('VvvvvvvVVVvvvvvVV'))
      io.write(record[:name])
    end

    # The permission bits live in the upper half; the lower half carries the
    # MS-DOS attribute byte, where bit 4 marks a directory.
    def external_attributes(record)
      (record[:mode] << 16) | (record[:directory] ? 0x10 : 0)
    end

    # MS-DOS packs a timestamp into two 16-bit words with a two-second
    # resolution and 1980 as its epoch. Anything older has no representation,
    # so it is clamped rather than wrapped into a date from the future.
    def dos_time(time)
      time = time.utc
      ((time.hour & 0x1f) << 11) | ((time.min & 0x3f) << 5) | ((time.sec / 2) & 0x1f)
    end

    def dos_date(time)
      time = time.utc
      year = [time.year - 1980, 0].max
      ((year & 0x7f) << 9) | ((time.month & 0x0f) << 5) | (time.day & 0x1f)
    end
  end
end
