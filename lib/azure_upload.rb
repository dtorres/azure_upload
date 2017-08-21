require 'azure_upload/version'

require 'date'
require 'in_threads'
require 'azure/storage'
require 'azure_mgmt_cdn'
require 'pathname'
require 'mime/types'
require 'yaml'
require 'logger'

module AzureUpload
  MAX_PROCESS = 10
  DEFAULT_CONFIG_FILE = '.azure_upload.yml'.freeze
  @config = {}
  @logger = Logger.new(STDOUT)

  def self.cache_paths(uploader)
    container_dir = '/' + uploader.container_name + '/'
    uploader.updated_paths.compact.map { |x| container_dir + x.to_path }
  end

  def self.configure(config_path)
    file = File.open(config_path)
    hash = YAML.safe_load(file)
    @config.merge!(hash) if hash.is_a? Hash
  end

  def self.ensure_required_config(config)
    failed = false
    %w[client_id subscription_id private_key tenant_id].each do |key|
      next unless config[key].nil?
      @logger.error "'#{key}' could not be found"
      failed = true
    end
    if failed
      config_file = DEFAULT_CONFIG_FILE
      @logger.error 'Provide the necessary keys by calling `configure`'
      text = "Alternatively they will be fetched from '#{config_file}'"
      text += ' in your home directory'
      @logger.error text
    end
    failed
  end

  def self.bust_cache(paths, res_group_name = nil, profile_name = nil, endpoint_name = nil)
    config_file = DEFAULT_CONFIG_FILE
    configure(File.expand_path('~/' + config_file)) if @config.empty?

    cdn = @config['CDN'] || {}
    errors = []
    res_group_name ||= cdn['resource_group'] || errors.push('Resource group not specified')
    profile_name ||= cdn['profile'] || errors.push('Profile not specified')
    endpoint_name ||= cdn['endpoint'] || errors.push('Endpoint not specified')

    return_early = false
    unless errors.empty?
      errors.each(&@logger.method(:error))
      @logger.error 'Provide the necessary arguments in `bust_cache`'
      error = "Alternatively they will be fetched from '#{config_file}'"
      error += " in your home directory. Set a hash under the key 'CDN'"
      @logger.error error
      return_early = true
    end
    return_early = ensure_required_config(@config) || return_early
    return if return_early

    _bust_cache(paths, res_group_name, profile_name, endpoint_name)
  end

  def self._cdn_client
    client_id = @config['client_id']
    sub_id = @config['subscription_id']
    cdn_key = @config['private_key']
    tenant_id = @config['tenant_id']

    token_class = MsRestAzure::ApplicationTokenProvider
    provider = token_class.new(tenant_id, client_id, cdn_key)
    credentials = MsRest::TokenCredentials.new(provider)
    cdn_client = Azure::ARM::CDN::CdnManagementClient.new(credentials)
    cdn_client.subscription_id = sub_id
    cdn_client
  end

  def self._bust_cache(paths, group, profile, endpoint)
    cdn_client = _cdn_client
    start = 0
    max_paths = 50
    while start < paths.count
      sub_paths = paths[start, max_paths]
      params = Azure::ARM::CDN::Models::PurgeParameters.new
      params.content_paths = sub_paths
      endpoints = cdn_client.endpoints
      promise = endpoints.begin_purge_content_async(group, profile, endpoint, params)
      @logger.info promise.value!.response.status
      start += max_paths
      if start < paths.count
        @logger.info 'Sleeping for 3 mins before continuing'
        sleep(3 * 60)
      end
    end
  end

  class Uploader
    attr_reader :updated_paths, :container_name
    attr_accessor :process_all
    def initialize(blobs, container_name, dir_to_upload)
      @blobs = blobs
      @container_name = container_name
      @dir_to_upload = Pathname.new(dir_to_upload)
      @updated_paths = []
      @logger = Logger.new(STDOUT)
      @logger.level = Logger::INFO
      @process_all = false
    end

    def upload
      upload_dir(@dir_to_upload, nil)
    end

    private

    def upload_dir(dir, latest_date)
      entries = Dir.entries(dir)[2..-1].map do |f|
        path = File.join(dir, f)
        {
          path: path,
          mtime: File.mtime(path)
        }
      end
      entries.sort_by! { |x| x[:mtime] }.reverse!

      from = 0
      count = 0
      process_more = true
      while process_more
        to_process = []
        while from + count < entries.count
          maybe = entries[from + count]
          if File.basename(maybe[:path])[0] == '.'
            from += 1
            next
          end
          is_older = latest_date && maybe[:mtime] < latest_date
          if !process_all && is_older
            @logger.debug 'Breaking because date!'
            process_more = false
            break
          end

          break unless count < MAX_PROCESS

          to_process << maybe
          count += 1
        end

        process_more = false if from + count >= entries.count

        from += count
        count = 0

        # Process directories concurrently
        dates = to_process.in_threads(MAX_PROCESS).map do |h|
          f = h[:path]
          if File.directory? f
            upload_dir(f, latest_date)
          else
            mtime = h[:mtime]
            upload_file(f, mtime)
          end
        end.compact
        latest_date = dates.map { |x| x[:date] }.compact.max
        @updated_paths += dates.map { |x| x[:uploaded_path] }.compact
      end
      { date: latest_date }
    end

    def upload_file(path, mdate)
      relative = Pathname.new(path).relative_path_from(@dir_to_upload)
      local_hash = Digest::MD5.file(path).base64digest
      upload = false
      existed = false
      begin
        blob = @blobs.get_blob_properties(@container_name, relative)
        remote_hash = blob.properties[:content_md5]
        upload = local_hash != remote_hash
        existed = true
      rescue Azure::Core::Http::HTTPError => error
        upload = error.status_code == 404
      end
      unless upload
        @logger.debug 'Have date'
        return { date: mdate, uploaded_path: nil }
      end

      puts "Processing file: #{path}"
      io = File.open(path)
      mime = MIME::Types.type_for(File.basename(path))
      mime = mime[0] if mime.is_a? Array
      options = {
        content_md5: local_hash,
        content_type: mime.content_type
      }
      @blobs.create_block_blob(@container_name, relative, io, options)
      return { uploaded_path: relative } if existed
      nil
    end
  end
end
