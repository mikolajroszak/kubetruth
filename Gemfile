source "https://rubygems.org"

# development dependencies
group :development do
  gem "rake"
  gem "pry"
  gem "pry-byebug"
  gem "ruby-debug-ide"
  gem "debase"
  gem "solargraph", ">= 0.44.3"
end

# test dependencies
group :development, :test do
  gem "rspec"
  gem "vcr"
  gem "webmock", ">= 3.14.0"
  gem 'codecov', require: false, group: 'test'
  gem "simplecov"
end

# application runtime dependencies
gem 'gem_logger'
gem 'logging'
gem 'activesupport'
gem 'clamp'
gem 'cloudtruth-client', path: "client"
gem 'kubeclient'
gem 'liquid'
gem 'yaml-safe_load_stream', git: "https://github.com/wr0ngway/yaml-safe_load_stream.git", branch: "ruby_3"
gem 'async'
