require 'erb'
require 'codenet_bugs'

module CodenetBugs
  class JUnitGenerator
    def initialize(bugs, tests, output_dir:, version:)
      @bugs = bugs
      @output_dir = output_dir
      @tests = tests
      @version = version
    end

    def generate!
      @time = Time.now
      @bugs.each do |bug|
        bug_tests = @tests[bug.problem_id]
        generate_single bug, bug_tests
      end
    end

    private

    def generate_single(bug, tests)
      package_name = "codenet_bugs_#{bug.id}"
      template = File.read(File.join(CodenetBugs.data_dir, 'templates', 'BugTest.java.erb'))
      submission = bug.submission @version
      test_class_name = "#{submission.main_class}Test"
      erb = ERB.new(template)

      base_dir = File.join(@output_dir, package_name)
      FileUtils.mkdir_p base_dir
      content = erb.result(binding)
      File.write(File.join(base_dir, "#{test_class_name}.java"), content)

      bug_code = "package #{package_name};\n#{submission.code}"
      File.write(File.join(base_dir, "#{submission.main_class}.java"), bug_code)

      puts base_dir
    end

  end
end