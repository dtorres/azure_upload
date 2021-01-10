require 'azure_upload/version'

require 'date'
require 'in_threads'
require 'azure/storage'
require 'azure_mgmt_cdn'
require 'pathname'
require 'mime/types'
require 'active_support/core_ext/hash'
require 'yaml'
require 'logger'

module AzureUpload
  DEFAULT_CONFIG_FILE = '.azure_upload.yml'.freeze
  @config = {}
  @logger = Logger.new(STDOUT)

  def self.cache_paths(uploader)
    container_dir = '/' + uploader.container_name + '/'
    uploader.updated_paths.compact.map { |x| container_dir + x.to_path }
  end

  def self.configure(config_path, overwrite = true)
    hash =
      if config_path.is_a? Hash
        config_path.symbolize_keys
      else
        file = File.open(config_path)
        YAML.safe_load(file).symbolize_keys
      end
    return unless hash.is_a? Hash
    if overwrite
      @config.merge!(hash)
    else
      @config = hash.merge!(@config)
    end
  end

  def self.configure_if_needed
    config_file = DEFAULT_CONFIG_FILE
    path = File.expand_path('~/' + config_file)
    configure(path, false) if @config.empty? && File.exist?(path)
  end

  def self.ensure_required_config_keys(keys, msg, subpath = [], config = nil)
    failed = false
    config ||= @config
    keys.each do |key|
      next unless config[key.to_sym].nil?
      @logger.error "'#{key}' could not be found"
      failed = true
    end
    if failed
      config_file = DEFAULT_CONFIG_FILE
      @logger.error msg
      text = "Alternatively they can be fetched from '#{config_file}'"
      text += ' in your home directory.'
      text += " Set a hash under the keypath '#{subpath.join('.')}'"
      @logger.error text
    end
    failed
  end

  def self.bust_cache(paths, opts = {})
    configure_if_needed
    keys = %i[resource_group profile endpoint]
    opts = opts.symbolize_keys
    opts = (@config[:CDN] || {}).symbolize_keys.merge(opts)
    msg = 'Provide the necessary options in `bust_cache`'
    return_early = ensure_required_config_keys(keys, msg, [:CDN], opts)

    keys = %i[client_id subscription_id private_key tenant_id]
    msg = 'Provide the necessary keys by calling `configure`'
    return_early = ensure_required_config_keys(keys, msg) || return_early
    return if return_early

    _bust_cache(paths, opts)
  end

  def self._bust_cache(paths, opts)
    endpoints = _cdn_client.endpoints
    start = 0
    max_paths = 50
    grp = opts[:resource_group]
    profile = opts[:profile]
    endp = opts[:endpoint]
    while start < paths.count
      params = Azure::CDN::Profiles::Latest::Mgmt::Models::PurgeParameters.new
      params.content_paths = paths[start, max_paths]
      promise = endpoints.begin_purge_content_async(grp, profile, endp, params)
      @logger.info promise.value!.response.status
      start += max_paths
      if start < paths.count
        @logger.info 'Sleeping for 3 mins before continuing'
        sleep(3 * 60)
      end
    end
  end

  def self._cdn_client
    client_id = @config[:client_id]
    sub_id = @config[:subscription_id]
    cdn_key = @config[:private_key]
    tenant_id = @config[:tenant_id]

    token_class = MsRestAzure::ApplicationTokenProvider
    provider = token_class.new(tenant_id, client_id, cdn_key)
    credentials = MsRest::TokenCredentials.new(provider)
    cdn_client = Azure::CDN::Profiles::Latest::Mgmt::Client.new(credentials: credentials, subscription_id: sub_id)
    cdn_client
  end

  def self.blobs
    configure_if_needed
    configure({
                storage_account: ENV['AZURE_STORAGE_ACCOUNT'],
                storage_access_key: ENV['AZURE_STORAGE_ACCESS_KEY']
              }, false)
    account = @config[:storage_account]
    access_key = @config[:storage_access_key]
    errors = []
    errors << 'Account name not found' unless account
    errors << 'Access key not found' unless access_key
    errors.each(&@logger.method(:error))
    exit(1) unless errors.empty?
    params = {
      storage_account_name: account,
      storage_access_key: access_key
    }
    client = Azure::Storage::Client.create(params)
    client.blob_client
  end

  class Uploader
    MAX_PROCESS = 10
    attr_reader :updated_paths, :container_name
    attr_accessor :process_all
    def initialize(container_name, dir_to_upload, blobs = nil)
      @blobs = blobs || AzureUpload.blobs
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
