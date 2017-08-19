require "azure_upload/version"

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
    DEFAULT_CONFIG_FILE = ".azure_upload.yml"
    @config = {}
    @logger = Logger.new(STDOUT)
    
    def self.cache_paths(uploader)
        container_dir = "/" + uploader.container_name + "/"
        uploader.updated_paths.compact.map {|x| container_dir + x.to_path}
    end

    def self.configure(config_path)
        file = File.open(config_path)
        hash = YAML.load(file)
        @config.merge!(hash) if hash.is_a? Hash
    end
    
    def self.ensure_required_config(config)
        failed = false
        ["client_id", "subscription_id", "private_key", "tenant_id"].each do |key|
          unless config[key].nil?
            return
          end
          @logger.error "'#{key}' could not be found" 
          failed = true
        end
        if failed
          @logger.error "Provide the necessary keys by calling `configure`"
          @logger.error "Alternatively they will be fetched from '#{DEFAULT_CONFIG_FILE}' in your home directory"
        end
        failed
    end
    
    
    
    def self.bust_cache(paths, res_group_name = nil, profile_name = nil, endpoint_name = nil)
        configure(File.expand_path("~/"+DEFAULT_CONFIG_FILE)) if @config.empty?
        
        client_id = @config["client_id"]
        sub_id = @config["subscription_id"]
        cdn_key = @config["private_key"]
        tenant_id = @config["tenant_id"]

        cdn_config = @config["CDN"] || {}
        cdn_errors = []
        res_group_name ||= cdn_config["resource_group"] || cdn_errors.push("Resource group not specified")
        profile_name ||= cdn_config["profile"] || cdn_errors.push("Profile not specified")
        endpoint_name ||= cdn_config["endpoint"] || cdn_errors.push("Endpoint not specified")
        
        return_early = false
        unless cdn_errors.empty?
          cdn_errors.each(&@logger.method(:error))
          @logger.error "Provide the necessary arguments in `bust_cache`"
          @logger.error "Alternatively they will be fetched from '#{DEFAULT_CONFIG_FILE}' in your home directory. Set a hash under the key 'CDN'"
          return_early = true
        end
        return_early = ensure_required_config(@config) || return_early
        if return_early
          return
        end
        
        provider = MsRestAzure::ApplicationTokenProvider.new(tenant_id, client_id, cdn_key)
    
        credentials = MsRest::TokenCredentials.new(provider)
        cdn_client = Azure::ARM::CDN::CdnManagementClient.new(credentials)
        cdn_client.subscription_id = sub_id
        
        start = 0
        max_paths = 50
        while start < paths.count
            sub_paths = paths[start, max_paths]
            params = Azure::ARM::CDN::Models::PurgeParameters.new
            params.content_paths = sub_paths
            promise = cdn_client.endpoints.begin_purge_content_async(res_group_name, profile_name, endpoint_name, params)
            @logger.info promise.value!.response.status
            start += max_paths
            if start < paths.count
                @logger.info "Sleeping for 3 mins before continuing"
                sleep(3*60)
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
            process_all = false
        end
        
        def upload
            upload_dir(@dir_to_upload, nil)
        end
        
        private
        def upload_dir(dir, latest_existing_date)
            entries = Dir.entries(dir)[2..-1].map{|f|
                path = File.join(dir, f)
                {
                    :path => path,
                    :mtime => File.mtime(path)
                }
            }
            entries.sort_by!{|x| x[:mtime]}.reverse!
            
            from = 0
            count = 0
            process_more = true
            while process_more
                last_date = nil
                to_process = []
                while from + count < entries.count
                    maybe = entries[from+count]
                    if File.basename(maybe[:path])[0] == "."
                        from += 1
                        next
                    end
                    if !process_all && (!latest_existing_date.nil? && maybe[:mtime] < latest_existing_date)
                        @logger.debug "Breaking because date!"
                        process_more = false
                        break
                    end
                    
                    if count < MAX_PROCESS
                        to_process << maybe
                        last_date = maybe[:mtime]
                        count += 1
                        else
                        break
                    end
                end
                
                if from+count >= entries.count
                    process_more = false
                end
                
                from += count
                count = 0
                
                #Process directories concurrently
                dates = to_process.in_threads(MAX_PROCESS).map { |h|
                    f = h[:path]
                    if File.directory? f
                        upload_dir(f, latest_existing_date)
                    else
                        mtime = h[:mtime]
                        upload_file(f, mtime, dir)
                    end
                }.compact
                latest_existing_date = dates.map{|x| x[:date]}.compact.max
                @updated_paths += dates.map{|x| x[:uploaded_path]}.compact
            end
            return {:date => latest_existing_date }
        end
        
        def upload_file(path, mdate, dir)
            io = File.open(path)
            relative = Pathname.new(path).relative_path_from(@dir_to_upload)
            mime = MIME::Types.type_for(File.basename(path))
            mime = mime[0] if mime.is_a? Array

            local_hash = Digest::MD5.file(path).base64digest
            upload = false
            existed = false
            begin
                remote_hash = @blobs.get_blob_properties(@container_name, relative).properties[:content_md5]
                upload = local_hash != remote_hash
                existed = true
            rescue Azure::Core::Http::HTTPError => error
                upload = error.status_code == 404
            end
            if !upload
                @logger.debug "Have date"
                return {:date => mdate, :uploaded_path => nil }
            end
            puts "Processing file: #{path}"
            options = {
                :content_md5 => local_hash,
                :content_type => mime.content_type
            }
            @blobs.create_block_blob(@container_name, relative, io, options)
            if existed
                return {:uploaded_path => relative}
                else
                return nil
            end
        end
    end
end
