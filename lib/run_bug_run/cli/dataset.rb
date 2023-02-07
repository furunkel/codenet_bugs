require 'run_bug_run/dataset'

module RunBugRun
  module CLI
    class Dataset < SubCommand
      desc "version", "show current version"
      def version
        puts JSON.pretty_generate(RunBugRun::Dataset.last_version)
      end

      desc "versions", "list all versions"
      def versions
        puts JSON.pretty_generate(RunBugRun::Dataset.versions)
      end

      desc "download", "Download dataset at specific version"
      method_option :version, desc: 'Dataset version', type: :string, required: true
      method_option :force, desc: 'Force redownload', type: :boolean, default: false
      def download
        RunBugRun::Dataset.download(version: options[:version], force: options[:force])
      end
    end
  end
end