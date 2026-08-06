# frozen_string_literal: true

require_relative "lib/karst/version"

Gem::Specification.new do |spec|
  spec.name = "karst"
  spec.version = Karst::VERSION
  spec.authors = ["Karst contributors"]
  spec.summary = "Runtime evidence for Rails applications"
  spec.description = "Karst is a runtime evidence engine for Rails. Runtime capture is not implemented yet."
  spec.homepage = "https://github.com/SilenceDogood1984/karst"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "CHANGELOG.md", "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "LICENSE", "README.md",
                   "SECURITY.md"]
  spec.metadata["source_code_uri"] = "https://github.com/SilenceDogood1984/karst"
  spec.metadata["changelog_uri"] = "https://github.com/SilenceDogood1984/karst/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "activesupport", ">= 7.0", "< 9"
end
