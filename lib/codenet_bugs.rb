# frozen_string_literal: true

require_relative "codenet_bugs/version"

module CodenetBugs
  class Error < StandardError; end
  # Your code goes here...

  def self.root
    File.expand_path('..', __dir__)
  end

  def self.data_dir
    File.join(root, 'data')
  end
end
