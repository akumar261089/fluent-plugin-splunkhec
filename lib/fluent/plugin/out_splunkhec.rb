require 'fluent/output'
require 'net/http'
require 'yajl/json_gem'

module Fluent
  class SplunkHECOutput < BufferedOutput
    Fluent::Plugin.register_output('splunkhec', self)

    # Primary Splunk HEC configuration parameters
    config_param :host,     :string, :default => 'localhost'
    config_param :protocol, :string, :default => 'http'
    config_param :port,     :string, :default => '8088'
    config_param :token,    :string

    # Splunk event parameters
    config_param :index,               :string, :default => 'main'
    config_param :event_host,          :string, :default => nil
    config_param :source,              :string, :default => 'tag'
    config_param :sourcetype,          :string, :default => 'fluentd'
    config_param :send_event_as_json,  :bool,   :default => false
    config_param :usejson,             :bool,   :default => true
    config_param :send_batched_events, :bool,   :default => false

    # This method is called before starting.
    # Here we construct the Splunk HEC URL to POST data to
    # If the configuration is invalid, raise Fluent::ConfigError.
    def configure(conf)
      super
      @splunk_url = @protocol + '://' + @host + ':' + @port + '/services/collector/event'
      log.info 'splunkhec: sent data to ' + @splunk_url

      if conf['event_host'] == nil
        begin
          @event_host = `hostname`.delete!("\n")
        rescue
          @event_host = 'unknown'
        end
      end
    end

    def start
      super
    end

    def shutdown
      super
    end

    # This method is called when an event reaches to Fluentd.
    # Use msgpack to serialize the object.
    def format(tag, time, record)
      [tag, time, record].to_msgpack
    end

    # Loop through all records and sent them to Splunk
    def write(chunk)
      body = ''
      chunk.msgpack_each {|(tag,time,record)|
        # Parse record to Splunk event format
        case record
        when Integer
          event = record.to_s
        when Hash
          if @send_event_as_json
            event = record.to_json
          else
            event = record.to_json.gsub("\"", %q(\\\"))
          end
        else
          event = record
        end

        source = @source == 'tag' ? tag : @source

        # Build body for the POST request
        if !@usejson
          event = record["time"]+ " " + record["message"].to_json.gsub(/^"|"$/,"")
          body << '{"time":"'+ DateTime.parse(record["time"]).strftime("%Q") +'", "event":"' + event + '", "sourcetype" :"' + sourcetype + '", "source" :"' + @source + '", "index" :"' + @index + '", "host" : "' + @event_host + '"}'
        elsif @send_event_as_json
          body << '{"time" :' + time.to_s + ', "event" :' + event + ', "sourcetype" :"' + sourcetype + '", "source" :"' + source + '", "index" :"' + @index + '", "host" : "' + @event_host + '"}'
        else
          body << '{"time" :' + time.to_s + ', "event" :"' + event + '", "sourcetype" :"' + sourcetype + '", "source" :"' + source + '", "index" :"' + @index + '", "host" : "' + @event_host + '"}'
        end

        if @send_batched_events
          body << "\n"
        else
          send_to_splunk(body)
          body = ''
        end
      }

      if @send_batched_events
        send_to_splunk(body)
      end
    end

    def send_to_splunk(body)
      log.debug "splunkhec: " + body + "\n"

      uri = URI(@splunk_url)

      # Create client
      http = Net::HTTP.new(uri.host, uri.port)

      # Create request
      req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json; charset=utf-8", "Authorization" => "Splunk #{@token}")
      req.body = body

      # Handle SSL
      if @protocol == 'https'
        http.use_ssl = true
      end

      # Send Request
      res = http.request(req)

      log.debug "splunkhec: HTTP Response Status Code is #{res.code}"

      if res.code.to_i != 200
        body = JSON.parse(res.body)
        raise SplunkHECOutputError.new(body['text'], body['code'], body['invalid-event-number'], res.code)
      end
    end
  end

  class SplunkHECOutputError < StandardError
    def initialize(message, status_code, invalid_event_number, http_status_code)
      super("#{message} (http status code #{http_status_code}, status code #{status_code}, invalid event number #{invalid_event_number})")
    end
  end

end
