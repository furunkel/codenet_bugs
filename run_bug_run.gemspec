# frozen_string_literal: true

require_relative "lib/run_bug_run/version"

Gem::Specification.new do |spec|
  spec.name = "run_bug_run"
  spec.version = RunBugRun::VERSION
  spec.authors = ["furunkel"]
  spec.email = ["furunkel@polyadic.com"]

  spec.summary = "An automatic programing repair benchmark and dataset."
  spec.description = "An automatic programming repair benchmark and dataset."
  spec.homepage = "https://github.com/furunkel/run_bug_run"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["allowed_push_host"] = 'https://rubygems.org'

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/furunkel/run_bug_run"
  spec.metadata["changelog_uri"] = "https://github.com/furunkel/run_bug_run/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"
  spec.add_dependency "progressbar", "~> 1.11"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
