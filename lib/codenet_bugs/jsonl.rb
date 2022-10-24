require 'json'
require 'zlib'

module JSONL
  def load_file(filename, symbolize_names: true)
    Zlib::GzipReader.open(filename) do |gz|
      gz.each_line do |line|
        yield JSON.parse(line, symbolize_names: symbolize_names)
      end
    end
  end

  def write_file(filename, lines)
    Zlib::GzipWriter.open(filename) do |gz|
      lines.each do |line|
        gz.puts(JSON.fast_generate(line))
      end
    end
  end

  module_function :load_file, :write_file
end