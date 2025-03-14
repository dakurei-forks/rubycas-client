require 'casclient/frameworks/rails/filter'
require 'redis'
require 'redis-store'
require 'redis-activesupport'
require 'redis-actionpack'
require 'rack/session/abstract/id'

module CASClient
  module Tickets
    module Storage

      class ActiveModelRedisTicketStore < AbstractTicketStore

        def initialize(config={})
          RedisSessionStore.setup_client(config || {})
          RedisPgtiou.setup_client(config || {})
        end

        def store_service_session_lookup(st, controller)
          raise CASException, 'No service_ticket specified.' unless st
          raise CASException, 'No controller specified.' unless controller

          st = st.ticket if st.kind_of? ServiceTicket
          session_id = session_id_from_controller(controller)
          # Create a session in the DB if it hasn't already been created.
          RedisSessionStore.req = controller.request

          unless RedisSessionStore.find_by_session_id(session_id)
            log.info("RubyCAS Client did not find #{session_id} in the Session Store. Creating it now!")
            # We need to use .save instead of .create or the service_ticket won't be stored
            new_session = RedisSessionStore.new
            new_session.service_ticket = st
            new_session.session_id = session_id
            controller.request.session_options[:id] = session_id

            if new_session.save
              # Set the rack session record variable so the service doesn't create a duplicate session and instead updates
              # the data attribute appropriately.
              obj_with_env = controller.respond_to?(:env) ? controller : controller.request
              obj_with_env.env['rack.session.record'] = new_session
            else
              raise CASException, "Unable to store session #{session_id} for service ticket #{st} in Redis."
            end
          else
            update_session(session_id, st)
          end
        end

        def get_session_for_service_ticket(st)
          session_id = read_service_session_lookup(st)
          session = session_id ? RedisSessionStore.find_by_session_id(session_id) : nil
          [session_id, session]
        end

        def read_service_session_lookup(st)
          raise CASException, 'No service_ticket specified.' unless st
          st = st.ticket if st.kind_of? ServiceTicket
          RedisSessionStore.find_by_service_ticket(st)
        end

        def cleanup_service_session_lookup(st)
          #no cleanup needed for this ticket store
          #we still raise the exception for API compliance
          raise CASException, 'No service_ticket specified.' unless st
        end

        def save_pgt_iou(pgt_iou, pgt)
          raise CASClient::CASException.new('Invalid pgt_iou') unless pgt_iou
          raise CASClient::CASException.new('Invalid pgt') unless pgt
          pgtiou = RedisPgtiou.create(pgt_iou: pgt_iou, pgt_id: pgt)
        end

        def retrieve_pgt(pgt_iou)
          raise CASException, 'No pgt_iou specified. Cannot retrieve the pgt.' unless pgt_iou
          pgtiou = RedisPgtiou.find_by_pgt_iou(pgt_iou)
          raise CASException, 'Invalid pgt_iou specified. Perhaps this pgt has already been retrieved?' unless pgtiou

          pgt = pgtiou.pgt_id
          pgtiou.destroy
          pgt
        end

        private
        def update_session(session_id, service_ticket)
          session = RedisSessionStore.find_by_session_id(session_id)
          session["session_id"] = session_id
          session["service_ticket"] = service_ticket
          RedisSessionStore.write_session(session_id, session)
        end
      end

      ::ACTIVE_MODEL_REDIS_TICKET_STORE = ActiveModelRedisTicketStore

      class RedisSessionStore
        include ActiveModel
        attr_accessor :session_id, :service_ticket, :data

        class << self
          attr_accessor :client, :req
        end

        def initialize(options={})
          options.each do |key, val|
            self.instance_variable_set("@#{key}", val)
          end
          self
        end

        def [](key)
          self.instance_variable_get("@#{key}")
        end

        def []=(key, value)
          self.instance_variable_set("@#{key}", value)
        end

        def self.setup_client(config)
          @@client ||= ActionDispatch::Session::ActiveModelRedisStore.new(config ,config)
        end

        def self.find_by_session_id(session_id)
          session_id = namespaced_key(session_id)
          session = @@client.find_session(@req, session_id)[1]

          # Unlike Memcached, Redis .get returns a serialized hash...
          # Alternately, data could be saved as redis native hash data using redis.hmset and retrieved with .hgetall
          # However, some values may themselves be hashes which would then be stringified.
          session = JSON.parse(session) if session.is_a? String

          # A session is generated immediately without actually logging in, the below line
          # validates that we have a service_ticket so that we can store additional information
          if session
            RedisSessionStore.new(session)
          else
            false
          end
        end

        def self.write_session(session_id, new_session)
          @@client.write_session(@req, ::Rack::Session::SessionId.new(session_id), new_session.session_data)
        end


        def self.find_by_service_ticket(service_ticket)
          session_id = @@client.find_session(@req, namespaced_key(service_ticket))
          session = RedisSessionStore.find_by_session_id(session_id) if session_id
          session.session_id if session
        end

        def session_data
          data = {}
          self.instance_variables.each{ |key| data[key.to_s.sub(/\A@/, '')] = self[key.to_s.sub(/\A@/, '')] }
          data
        end

        def client
          self.class.client
        end

        # As Redis is a key value store we are storing the session in the form of
        # session_id => {session_data}
        #
        # We do also need to be able to retrieve the session using just the service_ticket, and as
        # this is a key value store - we need to store the service_ticket as a key - pointing to
        # the session_id which will give us the session data
        # service_ticket => session_id
        # session_id => {session_data}
        def save
          @@client.write_session(@req, namespaced_key(service_ticket), session_id)
          # It's easiest to convert data to json, then parse when reading above in .find_by_session_id.
          @@client.write_session(@req, namespaced_key(session_id), session_data.to_json)
        end

        def destroy
          @@client.delete_session(@req, namespaced_key(service_ticket))
          @@client.delete_session(@req, namespaced_key(session_id))
        end

        alias_method :save!, :save

        # Need to access the namespaced_key method through both class methods as
        # well as instance methods.
        # Hence having the same name methods for both class and instance.
        def self.namespaced_key(key)
          if @namespace
            ::Rack::Session::SessionId.new("#{@namespace}:#{key}")
          else
            ::Rack::Session::SessionId.new(key.to_s)
          end
        end

        def namespaced_key(key)
          self.class.namespaced_key(key)
        end
      end

      class RedisPgtiou
        include ActiveModel
        attr_accessor :pgt_iou, :pgt_id

        def initialize(options = {})
          @pgt_iou = options[:pgt_iou]
          @pgt_id = options[:pgt_id]
        end

        def self.setup_client(config)
          @@client ||= ActionDispatch::Session::ActiveModelRedisStore.new(config, config)
        end

        def self.find_by_pgt_iou(pgt_iou)
          pgtiou = @@client.find_session(RedisSessionStore.req, ::Rack::Session::SessionId.new(pgt_iou))[1]
          new(pgtiou) if pgtiou
        end

        def self.create(options)
          pgtiou = new(options)
          @@client.write_session(RedisSessionStore.req, ::Rack::Session::SessionId.new(pgtiou.pgt_iou), pgtiou.session_data)
        end

        def session_data
          { pgt_iou: pgt_iou, pgt_id: pgt_id }
        end

        def destroy
          @@client.delete_session(RedisSessionStore.req, ::Rack::Session::SessionId.new(pgt_iou))
        end
      end
    end
  end
end
