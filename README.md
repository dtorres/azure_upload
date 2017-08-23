# AzureUpload

AzureUpload is a simple gem that recursively uploads/updates* resources in a folder to a container in Azure Storage.

It also implements a cache purge utility that can be easily invoked with `updated_paths` available in the `Uploader` class after an upload. 

\* **Note:** Currently it does not delete files, so it cannot be used as a sync tool.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'azure_upload'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install azure_upload

## Setup

AzureUpload requires to be supplied a list of keys to connect with Azure. The corresponding keys are in parenthesis.

You can provide the keys by:  

- passing `AzureUpload.configure` a hash or a path to a YAML file
- putting the keys in `~/.azure_upload.yml`. They will be picked up automatically.

The library checks for these requirements and provides error messages on what is missing.

###Uploader
- Storage Account (*storage_account*): name of the azure account you are uploading to.
- Storage Access Key (*storage\_access\_key*): A private key to authenticate you.

You can obtain those details following [this guide](https://docs.microsoft.com/en-us/azure/storage/common/storage-create-storage-account) by Microsoft.

###CDN Purge
This API is older than the Uploader and for some reason requires way more parameters (and a bit obscure to get)

- Client Identifier (*client_id*)
- Subscription Identifier (*subscription_id*)
- Tenant Identifier (*tenant_id*)
- Private Key (*private_key*)  


You can obtain those details following [this guide](https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-create-service-principal-portal) by Microsoft

## Usage

```ruby
require 'azure_upload'

#Important: Supply capitalized variables

#Uploader
uploader = AzureUpload::Uploader.new(CONTAINER_NAME, PATH_TO_UPLOAD)
uploader.upload()

#CDN Purge
params = {
    resource_group: RESOURCE_GROUP_NAME,
    profile: PROFILE_NAME,
    endpoint: ENDPOINT_NAME
}

#Or an array of string paths if you didn't use an uploader
paths_to_bust = AzureUpload.cache_paths(uploader) 
AzureUpload.bust_cache(paths_to_bust, params)
```

For the CDN purge you can alternatively setup the parameters in the configuration step under the key `CDN`

## Development

After checking out the repo, run `bin/setup` to install dependencies. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/dtorres/azure_upload. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the AzureUpload project’s codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/dtorres/azure_upload/blob/master/CODE_OF_CONDUCT.md).
