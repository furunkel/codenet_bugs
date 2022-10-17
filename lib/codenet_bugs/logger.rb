require 'logger'

module CodenetBugs
  class Logger < ::Logger
    attr_reader :progress

    class Formatter
      def initialize(logger)
        @logger = logger
      end

      def call(severity, datetime, progname, msg)
        date_format = datetime.strftime("%Y-%m-%d %H:%M:%S")
        sprintf "[%d%%] [%s] %-5s: %s\n", (@logger.progress * 100).round(2), date_format, severity, msg
      end
    end

    def initialize
      super($stdout)
      @progress = 0.0
      self.formatter = Formatter.new(self)
    end

    def progress=(progress)
      @progress = [[@progress, progress].max, 1.0].min
    end
  end
end

