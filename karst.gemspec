# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "karst"
  spec.version = "0.0.0"
  spec.authors = ["Karst contributors"]
  spec.summary = "Runtime evidence for Rails applications"
  spec.description = "Karst is a runtime evidence engine for Rails. Runtime capture is not implemented yet."
  spec.homepage = "https://github.com/chdsbd/karst"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["CHANGELOG.md", "CODE_OF_CONDUCT.md", "CONTRIBUTING.md", "LICENSE", "README.md", "SECURITY.md"]
  spec.metadata["source_code_uri"] = "https://github.com/chdsbd/karst"
  spec.metadata["changelog_uri"] = "https://github.com/chdsbd/karst/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
