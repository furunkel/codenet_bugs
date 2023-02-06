require 'json'
require 'zlib'

module JSONUtils

  def decompress(io, compression, &block)
    case compression
    when :gzip
      io.rewind
      Zlib::GzipReader.wrap(io, &block)
    when :none
      block[io]
    else
      raise ArgumentError, 'invalid compression'
    end
  end

  def load_jsonl(io, compression:, symbolize_names: true)
    decompress(io, compression) do |decompressed_io|
      decompressed_io.each_line.map do |line|
        JSON.parse(line, symbolize_names:)
      end
    end
  end

  def load_json(io, compression:, symbolize_names: true)
    decompress(io, compression) do |decompressed_io|
      JSON.parse(decompressed_io.read, symbolize_names:)
    end
  end

  def load_file(filename, symbolize_names: true)
    File.open(filename) do |io|
      case filename
      when /\.jsonl$/
        load_jsonl(io, symbolize_names:, compression: :none)
      when /\.jsonl\.gz$/
        load_jsonl(io, symbolize_names:, compression: :gzip)
      when /\.json$/
        load_json(io, symbolize_names:, compression: :none)
      when /\.json\.gz$/
        load_json(io, symbolize_names:, compression: :gzip)
      else
        raise ArgumentError, "unknown file extension for #{filename}"
      end
    end
  end

  def load_internal(*path_parts, symbolize_names: true)
    full_filename = File.join(RunBugRun.data_dir, *path_parts)
    load_file(full_filename, symbolize_names:)
  end

  def write_jsonl(filename, rows)
    open(filename) do |io|
      rows.each do |row|
        io.puts(JSON.fast_generate(rows))
      end
    end
  end

  module_function :load_file, :write_jsonl, :load_json, :load_jsonl, :decompress, :load_internal
end