require 'run_bug_run/dataset'

module RunBugRun
  module CLI
    class Dataset < SubCommand
      desc "version", "show current dataset version"
      def create
        # create
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