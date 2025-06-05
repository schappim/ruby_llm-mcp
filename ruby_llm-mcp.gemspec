# frozen_string_literal: true

require_relative "lib/ruby_llm/mcp/version"

# rubocop:disable Metrics/BlockLength
Gem::Specification.new do |spec|
  spec.name = "ruby_llm-mcp"
  spec.version = RubyLLM::MCP::VERSION
  spec.authors = ["Patrick Vice"]
  spec.email = ["patrickgvice@gmail.com"]

  spec.summary = "A RubyLLM MCP Client"
  spec.description = <<~DESC
    A Ruby client for the Model Context Protocol (MCP) that seamlessly integrates with RubyLLM.
    Connect to MCP servers via SSE or stdio transports, automatically convert MCP tools into
    RubyLLM-compatible tools, and enable AI models to interact with external data sources and
    services. Makes using MCP with RubyLLM as easy as possible.
  DESC

  spec.homepage = "https://github.com/patvice/ruby_llm-mcp"
  spec.license = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 3.1.0")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/patvice/ruby_llm-mcp"
  spec.metadata["changelog_uri"] = "#{spec.metadata['source_code_uri']}/commits/main"
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.metadata['source_code_uri']}/issues"

  spec.metadata["rubygems_mfa_required"] = "true"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.glob("lib/**/*") + ["README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", ENV["FARADAY_VERSION"] || ">= 1.10.0"
  spec.add_dependency "faraday-multipart", ">= 1"
  spec.add_dependency "faraday-net_http", ">= 1"
  spec.add_dependency "faraday-retry", ">= 1"
  spec.add_dependency "ruby_llm", "~> 1.2"
  spec.add_dependency "zeitwerk", "~> 2"
end
# rubocop:enable Metrics/BlockLength
