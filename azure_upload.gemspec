# coding: utf-8
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "azure_upload/version"

Gem::Specification.new do |spec|
  spec.name          = "azure_upload"
  spec.version       = AzureUpload::VERSION
  spec.authors       = ["Diego Torres"]
  spec.email         = ["contact@dtorres.me"]

  spec.summary       = "Basic Azure Uploader"
  spec.description   = "Easily upload to Azure Storage and bust the cache of modified files"
  spec.license       = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata["allowed_push_host"] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against " \
      "public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.require_paths = ["lib"]
  
  spec.add_dependency 'in_threads'
  spec.add_dependency 'mime-types'
  spec.add_dependency 'azure-storage'
  spec.add_dependency 'azure_mgmt_cdn'
  
  spec.add_development_dependency "bundler", "~> 1.15"
  spec.add_development_dependency "rake", "~> 10.0"
end
