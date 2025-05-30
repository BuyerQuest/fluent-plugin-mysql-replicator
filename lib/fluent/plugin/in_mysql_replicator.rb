require 'mysql2'
require 'digest/sha1'
require 'fluent/plugin/input'

module Fluent::Plugin
  class MysqlReplicatorInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('mysql_replicator', self)

    helpers :thread, :storage
    DEFAULT_STORAGE_TYPE = 'local'

    # If the config does not include a <storage> section we simply keep
    # state in‑memory and lose it on restart.

    config_param :host, :string, :default => 'localhost'
    config_param :port, :integer, :default => 3306
    config_param :username, :string, :default => 'root'
    config_param :password, :string, :default => nil, :secret => true
    config_param :database, :string, :default => nil
    config_param :encoding, :string, :default => 'utf8'
    config_param :query, :string
    config_param :prepared_query, :string, :default => nil
    config_param :primary_key, :string, :default => 'id'
    config_param :interval, :string, :default => '1m'
    config_param :enable_delete, :bool, :default => true
    config_param :tag, :string, :default => nil

    def configure(conf)
      super
      @interval = Fluent::Config.time_value(@interval)

      if @tag.nil?
        raise Fluent::ConfigError, "mysql_replicator: missing 'tag' parameter. Please add following line into config like 'tag replicator.mydatabase.mytable.${event}.${primary_key}'"
      end

      # Create a storage backend only if the user actually provided one.
      storage_conf = conf.elements(name: 'storage').first
      if storage_conf
        @checkpoint = storage_create(usage: 'checkpoint', conf: storage_conf,
                                     default_type: DEFAULT_STORAGE_TYPE)
      else
        log.warn "mysql_replicator: no <storage> section found – state will NOT survive a restart."
        @checkpoint = nil
      end

      log.info "adding mysql_replicator worker. :tag=>#{tag} :query=>#{@query} :prepared_query=>#{@prepared_query} :interval=>#{@interval}sec :enable_delete=>#{enable_delete}"
    end

    def start
      super

      # Reload the last checkpoint (or start fresh)
      if @checkpoint
        raw_hash = @checkpoint.get(:table_hash)
        # Convert `[[k,v], ...]` back into {k=>v} if we stored an array
        @table_hash = case raw_hash
                      when Array
                        raw_hash.to_h
                      when Hash
                        raw_hash
                      else
                        {}
                      end
        @ids = (@checkpoint.get(:ids) || [])
      else
        @table_hash = {}
        @ids        = []
      end

      thread_create(:in_mysql_replicator_runner, &method(:run))
    end

    def shutdown
     super
    end

    def run
      begin
        poll
      rescue StandardError => e
        log.error "mysql_replicator: failed to execute query."
        log.error "error: #{e.message}"
        log.error e.backtrace.join("\n")
      end
    end

    def poll
      loop do
        con = get_connection()
        prepared_con = get_connection()
        changes_emitted = false
        rows_count = 0
        start_time = Time.now
        previous_ids = @ids.dup
        current_ids = Array.new
        if !@prepared_query.nil?
          @prepared_query.split(/;/).each do |query|
            prepared_con.query(query)
          end
        end
        rows, con = query(@query, con)
        rows.each do |row|
          current_ids << row[@primary_key]
          current_hash = Digest::SHA1.hexdigest(row.flatten.join)
          row.each {|k, v| row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
          row.select {|k, v| v.to_s.strip.match(/^SELECT(\s+)/i) }.each do |k, v|
            row[k] = [] unless row[k].is_a?(Array)
            nested_sql = v.gsub(/\$\{([^\}]+)\}/) { row[Regexp.last_match(1)].to_s }
            nest_rows, prepared_con = query(nested_sql, prepared_con)
            nest_rows.each do |nest_row|
              nest_row.each {|k, v| nest_row[k] = v.to_s if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(BigDecimal)}
              row[k] << nest_row
            end
          end
          if row[@primary_key].nil?
            log.error "mysql_replicator: missing primary_key. :tag=>#{tag} :primary_key=>#{primary_key}"
            break
          end
          if !@table_hash.include?(row[@primary_key])
            tag = format_tag(@tag, {:event => :insert})
            emit_record(tag, row)
            changes_emitted = true
          elsif @table_hash[row[@primary_key]] != current_hash
            tag = format_tag(@tag, {:event => :update})
            emit_record(tag, row)
            changes_emitted = true
          end
          @table_hash[row[@primary_key]] = current_hash
          rows_count += 1
        end
        con.close
        prepared_con.close
        @ids = current_ids
        if @enable_delete
          if current_ids.empty?
            deleted_ids = Array.new
          elsif previous_ids.empty?
            deleted_ids = [*1...current_ids.max] - current_ids
          else
            deleted_ids = previous_ids - current_ids
          end
          if deleted_ids.count > 0
            hash_delete_by_list(@table_hash, deleted_ids)
            deleted_ids.each do |id|
              tag = format_tag(@tag, {:event => :delete})
              emit_record(tag, {@primary_key => id})
              changes_emitted = true
            end
          end
        end
        elapsed_time = sprintf("%0.02f", Time.now - start_time)
        log.debug "mysql_replicator: finished execution :tag=>#{@tag} :rows_count=>#{rows_count} :elapsed_time=>#{elapsed_time} sec"

        # Persist checkpoint only when we actually emitted insert/update/delete events
        if changes_emitted && @checkpoint
          # Store as array-of-pairs to preserve native key types in JSON/MessagePack
          @checkpoint.put(:table_hash, @table_hash.map { |k, v| [k, v] })
          @checkpoint.put(:ids, @ids)
          # ensure the data hits disk immediately
          @checkpoint.save
        end
        
        # Sleep for the specified interval
        sleep @interval
      end
    end

    def hash_delete_by_list (hash, deleted_keys)
      deleted_keys.each{|k| hash.delete(k)}
    end

    def format_tag(tag, param)
      pattern = {'${event}' => param[:event].to_s, '${primary_key}' => @primary_key}
      tag.gsub(/(\${[a-z_]+})/) do
        log.warn "mysql_replicator: missing placeholder. :tag=>#{tag} :placeholder=>#{$1}" unless pattern.include?($1)
        pattern[$1]
      end
    end

    def emit_record(tag, record)
      router.emit(tag, Fluent::Engine.now, record)
    end

    def query(query, con = nil)
      begin
        con = con.nil? ? get_connection : con
        con = con.ping ? con : get_connection
        return con.query(query), con
      rescue Exception => e
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end

    def get_connection
      begin
        return Mysql2::Client.new({
          :host => @host,
          :port => @port,
          :username => @username,
          :password => @password,
          :database => @database,
          :encoding => @encoding,
          :reconnect => true,
          :stream => true,
          :cache_rows => false
        })
      rescue Exception => e
        log.warn "mysql_replicator: #{e}"
        sleep @interval
        retry
      end
    end
  end
end
