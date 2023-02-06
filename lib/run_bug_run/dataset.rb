require 'open-uri'
require 'progressbar'
require 'digest'

require 'run_bug_run/bugs'

module RunBugRun
  class Dataset
    #DEFAULT_BASE_URL = 'https://github.com/gigianticode/run_bug_run/%{version}/%{filename}'.freeze
    DEFAULT_BASE_URL = 'https://github.com/furunkel/run_bug_run_data/releases/download/v%{version}/%{filename}'.freeze
    MANIFEST_FILENAME = 'Manifest.json.gz'.freeze

    class << self
      def last_version
        Dir[versions_dir].max_by {  Gem::Version.new(_1) }
      end

      def versions
        Dir[versions_dir].max_by {  Gem::Version.new(_1) }
      end

      def versions_dir
        File.join(RunBugRun.data_dir, 'versions')
      end

      def download(version:, force: false, base_url: DEFAULT_BASE_URL)
        manifest_io = download_file(MANIFEST_FILENAME, version, force:, base_url:)
        manifest_io.rewind
        manifest = JSONUtils.load_json(manifest_io, compression: :gzip)

        pp manifest

        bugs = manifest.fetch(:bugs)
        tests = manifest.fetch(:tests)
        total_bytes = 0
        total_bytes += bugs.sum { _1.fetch(:bytes) }
        total_bytes += tests.sum { _1.fetch(:bytes) }

        progress_bar = ProgressBar.create(total: total_bytes)

        downloaded_bytes = 0
        progress_proc = lambda do |progress|
          progress_bar.progress = downloaded_bytes + progress
        end

        (bugs + tests).each do |file|
          language = file[:language]
          progress_bar.title =
            if language
              "Downloading #{Bugs::LANGUAGE_NAME_MAP[language.to_sym]}"
            else
              "Downlaoding tests"
            end

          download_file(file.fetch(:filename), manifest.fetch(:version), force:, base_url:, progress_proc:, md5: file.fetch(:md5))
          downloaded_bytes += file.fetch(:bytes)
        end
      ensure
        manifest_io&.close
      end

      def download_file(filename, version, force:, base_url:, progress_proc: nil, md5: nil)
        url = format(base_url, version:, filename:)
        uri = URI.parse(url)
        target_path = File.join(versions_dir, version, filename)
        if !force && File.exist?(target_path)
          return File.open(target_path, 'r')
        end

        RunBugRun.logger.debug("Downloading '#{url}' to #{target_path}")

        download = uri.open(
          # content_length_proc: lambda { |content_length|
          #   if total_bytes.nil? && content_length&.positive?
          #     progress_bar.total = content_length
          #   end
          # },
          progress_proc:
        )

        FileUtils.mkdir_p(File.dirname(target_path))
        IO.copy_stream(download, target_path)

        if md5
          download.rewind
          if md5 != Digest::MD5.hexdigest(download.read)
            RunBugRun.logger.warn "md5 check failed, please redownload. Use --force to overwrite previous files"
          end
        end

        download
      end
    end
  end
end