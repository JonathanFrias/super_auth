# frozen_string_literal: true

require_relative "lib/super_auth/version"

Gem::Specification.new do |spec|
  spec.name = "super_auth"
  spec.version = SuperAuth::VERSION
  spec.authors = ["Jonathan Frias"]
  spec.email = ["jonathan@gofrias.com"]

  spec.summary = "Make Unauthenticated State Unrepresentable"
  spec.description = "Simple, yet super powerful authorization for you application"
  spec.homepage = "https://github.com/JonathanFrias/super_auth"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/JonathanFrias/super_auth"
  spec.metadata["changelog_uri"] = "https://github.com/JonathanFrias/super_auth/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|circleci)|appveyor)})
    end
  end
  spec.bindir = "bin"
  spec.executables = spec.files.grep(%r{\Abin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  spec.add_dependency "sequel"
  spec.add_development_dependency "sqlite3"
  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
