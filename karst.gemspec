# frozen_string_literal: true

require_relative "lib/karst/version"

Gem::Specification.new do |spec|
  spec.name = "karst"
  spec.version = Karst::VERSION
  spec.authors = ["Karst contributors"]
  spec.summary = "Find real users who can access Rails routes"
  spec.description = "Karst tests Rails routes as a bounded set of existing users and reports runtime access evidence."
  spec.homepage = "https://github.com/SilenceDogood1984/karst"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.rake", "docs/**/*", "ARCHITECTURE.md", "CHANGELOG.md", "CODE_OF_CONDUCT.md",
                   "CONTRIBUTING.md", "LICENSE", "README.md", "SECURITY.md"]
  spec.metadata["source_code_uri"] = "https://github.com/SilenceDogood1984/karst"
  spec.metadata["changelog_uri"] = "https://github.com/SilenceDogood1984/karst/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_dependency "activesupport", ">= 6.1", "< 9"
  # All repository Gemfiles use `gemspec`, so this keeps MCP available to
  # adapter specs across the Rails matrix without making it a runtime dependency.
  # rubocop:disable Gemspec/DevelopmentDependencies
  spec.add_development_dependency "mcp", "~> 0.9.0"
  # rubocop:enable Gemspec/DevelopmentDependencies
end
