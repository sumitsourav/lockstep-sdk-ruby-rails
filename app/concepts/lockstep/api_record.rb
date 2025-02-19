require 'rubygems'
require 'bundler/setup'
require 'active_model'
require 'erb'
require 'dry-types'
require 'json'
require 'active_support/hash_with_indifferent_access'
require 'lockstep/query'
require 'lockstep/query_methods'
require 'lockstep/error'
require 'lockstep/exceptions'
require 'lockstep/relation_array'
require 'pry'

module Lockstep
  class ApiRecord
    include Lockstep::ApiRecords::Scopes
    # Lockstep::ApiRecord provides an easy way to use Ruby to interace with a api.lockstep.io backend
    # Usage:
    #  class Post < Lockstep::ApiRecord
    #    fields :title, :author, :body
    #  end

    # @@has_many_relations = {}.with_indifferent_access
    # @@belongs_to_relations = {}.with_indifferent_access

    include ActiveModel::Validations
    include ActiveModel::Validations::Callbacks
    include ActiveModel::Conversion
    include ActiveModel::AttributeMethods
    extend ActiveModel::Naming
    extend ActiveModel::Callbacks
    HashWithIndifferentAccess = ActiveSupport::HashWithIndifferentAccess

    attr_accessor :error_instances

    define_model_callbacks :save, :create, :update, :destroy

    validate :validate_enum

    # Instantiates a Lockstep::ApiRecord object
    #
    # @params [Hash], [Boolean] a `Hash` of attributes and a `Boolean` that should be false only if the object already exists
    # @return [Lockstep::ApiRecord] an object that subclasses `Parseresource::Base`
    def initialize(attributes = {}, new = true)
      # attributes = HashWithIndifferentAccess.new(attributes)

      if new
        @unsaved_attributes = attributes
        @unsaved_attributes.stringify_keys!
      else
        @unsaved_attributes = {}
      end
      @attributes = {}
      self.error_instances = []

      attributes.each do |k, v|
        # Typecast using dry-types
        if (type = schema[k])
          attributes[k] = type[v]
        elsif v.present? and (enum = enum_config[k]).present? and enum.keys.include?(v.to_s)
          attributes[k] = enum[v]
        end
      end

      self.attributes.merge!(attributes)
      self.attributes unless self.attributes.empty?
      create_setters_and_getters!
    end

    def self.schema
      @schema ||= {}.with_indifferent_access
    end

    def schema
      self.class.schema
    end

    # Explicitly adds a field to the model.
    #
    # @param [Symbol] name the name of the field, eg `:author`.
    # @param [Boolean] val the return value of the field. Only use this within the class.
    def self.field(fname, type = nil)
      schema[fname] = type

      fname = fname.to_sym
      class_eval do
        define_method(fname) do
          val = get_attribute(fname.to_s)

          # If enum, substitute with the enum key
          if val.present? && (enum = enum_config[fname]).present?
            val = enum.key(val)
          end

          val
        end
      end
      unless respond_to? "#{fname}="
        class_eval do
          define_method("#{fname}=") do |val|
            set_attribute(fname.to_s, val)

            val
          end
        end
      end
    end

    # Add multiple fields in one line. Same as `#field`, but accepts multiple args.
    #
    # @param [Array] *args an array of `Symbol`s, `eg :author, :body, :title`.
    def self.fields(*args)
      args.each { |f| field(f) }
    end

    def belongs_to_relations
      @belongs_to_relations ||= {}
    end

    # Similar to its ActiveRecord counterpart.
    #
    # @param [Hash] options Added so that you can specify :class_name => '...'. It does nothing at all, but helps you write self-documenting code.
    # @primary_key is the attribute of the referenced :class_name
    # @foreign_key is the attribute of the parent class
    def self.belongs_to(parent, config = {})
      config = config.with_indifferent_access
      class_name = config[:class_name]
      raise "Class name cannot be empty in #{parent}: #{name}" if class_name.blank?

      included = config[:included] || false
      primary_key = config[:primary_key]
      foreign_key = config[:foreign_key]
      polymorphic = config[:polymorphic]
      loader = config[:loader]

      primary_key ||= class_name.constantize.id_ref
      foreign_key ||= class_name.constantize.id_ref
      field(parent)
      belongs_to_relations[parent] = {
        name: parent, class_name: class_name,
        included: included, primary_key: primary_key, foreign_key: foreign_key,
        loader: loader, polymorphic: polymorphic
      }

      # define_method("build_#{parent}") do |attributes_hash|
      #   build_belongs_to_association(parent, attributes_hash)
      # end
    end

    # Creates setter and getter in order access the specified relation for this Model
    #
    # @param [Hash] options Added so that you can specify :class_name => '...'. It does nothing at all, but helps you write self-documenting code.
    # @primary_key is the attribute of the parent_class
    # @foreign_key is the attribute of the referenced :class_name
    # @polymorphic is used to assign polymorphic association with the related ApiModel. It expects a hash with the key-value, or a lambda function which returns a hash
    def self.has_many(parent, config = {})
      config = config.with_indifferent_access
      class_name = config[:class_name]
      raise "Class name cannot be empty in #{parent}: #{name}" if class_name.blank?

      included = config[:included] || false
      primary_key = config[:primary_key]
      foreign_key = config[:foreign_key]
      polymorphic = config[:polymorphic]
      loader = config[:loader]

      primary_key ||= id_ref
      foreign_key ||= id_ref
      field(parent)
      has_many_relations[parent] = {
        name: parent, class_name: class_name, included: included,
        primary_key: primary_key, foreign_key: foreign_key, polymorphic: polymorphic,
        loader: loader
      }
    end

    def self.load_schema(schema)
      schema.schema.each do |field, type|
        field(field, type)
      end

      schema.belongs_to_relations.each do |relation, config|
        params = {}
        config.except(:name).each { |k, v| params[k.to_sym] = v }
        belongs_to(relation, params)
      end

      schema.has_many_relations.each do |relation, config|
        params = {}
        config.except(:name).each { |k, v| params[k.to_sym] = v }
        has_many(relation, params)
      end
    end

    def to_pointer
      klass_name = self.class.model_name.to_s
      { '__type' => 'Pointer', 'className' => klass_name.to_s, id_ref => id }
    end

    def self.to_date_object(date)
      date = date.to_time if date.respond_to?(:to_time)
      if date && (date.is_a?(Date) || date.is_a?(DateTime) || date.is_a?(Time))
       date.getutc.iso8601(fraction_digits = 3)
      end
    end

    # Creates setter methods for model fields
    def create_setters!(k, _v)
      unless respond_to? "#{k}="
        self.class.send(:define_method, "#{k}=") do |val|
          set_attribute(k.to_s, val)

          val
        end
      end
    end

    def method_missing(method, *_args)
      raise StandardError, "#{method} has not been defined for #{self.class.name}"
      # super
    end

    def self.method_missing(method_name, *args)
      method_name = method_name.to_s
      if method_name.start_with?('find_by_')
        attrib = method_name.gsub(/^find_by_/, '')
        finder_name = "find_all_by_#{attrib}"

        define_singleton_method(finder_name) do |target_value|
          where({ attrib.to_sym => target_value }).first
        end

        send(finder_name, args[0])
      elsif method_name.start_with?('find_all_by_')
        attrib = method_name.gsub(/^find_all_by_/, '')
        finder_name = "find_all_by_#{attrib}"

        define_singleton_method(finder_name) do |target_value|
          where({ attrib.to_sym => target_value }).all
        end

        send(finder_name, args[0])
      else
        super(method_name.to_sym, *args)
      end
    end

    # Creates getter methods for model fields
    def create_getters!(k, _v)
      unless respond_to? k.to_s
        self.class.send(:define_method, k.to_s) do
          get_attribute(k.to_s)
        end
      end
    end

    def create_setters_and_getters!
      @attributes.each_pair do |k, v|
        create_setters!(k, v)
        create_getters!(k, v)
      end
    end

    # @@settings ||= nil

    # Explicitly set Parse.com API keys.
    #
    # @param [String] app_id the Application ID of your Parse database
    # @param [String] master_key the Master Key of your Parse database
    # def self.load!(app_id, master_key)
    #   @@settings = { "app_id" => app_id, "master_key" => master_key }
    # end

    # def self.settings
    #   load_settings
    # end

    # # Gets the current class's model name for the URI
    # def self.model_name_uri
    #   # This is a workaround to allow the user to specify a custom class
    #   if defined?(self.parse_class_name)
    #     "#{self.parse_class_name}"
    #   else
    #     "#{self.model_name.to_s}"
    #   end
    # end

    class << self
      attr_writer :id_ref
    end

    def self.id_ref
      raise StandardError, "id_ref has not been defined for #{name}" if @id_ref.blank?

      @id_ref
    end

    # Alias for id_ref. Used by polymorphic association
    def self.primary_key
      id_ref
    end

    def id_ref
      self.class.id_ref
    end

    def self.model_name_uri=(val)
      @model_name_uri = val

      @model_name_uri
    end

    class << self
      attr_reader :model_name_uri
    end

    def self.config
      @config ||= Rails.application.config_for(:lockstep_client)
    end

    # Gets the current class's Lockstep.io base_uri
    def self.model_base_uri
      if name.starts_with?('Schema::')
        raise StandardError,
              'Cannot establish connection for auto-generated Schema. Create a new model if you want to retrieve data from Lockstep Platform'
      end
      raise StandardError, "URL Path is not defined for #{name}" if model_name_uri.blank?

      base_url = config[:base_url]
      base_url += '/' unless base_url.ends_with?('/')
      base_url += model_name_uri
      base_url += '/' unless base_url.ends_with?('/')
      base_url
    end

    # Gets the current instance's parent class's Parse.com base_uri
    def model_base_uri
      self.class.send(:model_base_uri)
    end

    # Creates a RESTful resource
    # sends requests to [base_uri]/[classname]
    #
    def self.resource
      # load_settings

      # refactor to settings['app_id'] etc
      # app_id     = @@settings['app_id']
      # master_key = @@settings['master_key']
      # RestClient::Resource.new(self.model_base_uri, app_id, master_key)
      Lockstep::Client.new(model_base_uri)
    end

    class << self
      attr_writer :query_path
    end

    def self.query_path
      @query_path || 'query'
    end

    # Batch requests
    # Sends multiple requests to /batch
    # Set slice_size to send larger batches. Defaults to 20 to prevent timeouts.
    # Parse doesn't support batches of over 20.
    #
    # def self.batch_save(save_objects, slice_size = 20, method = nil)
    #   return true if save_objects.blank?
    #
    #   res = self.resource
    #
    #   # Batch saves seem to fail if they're too big. We'll slice it up into multiple posts if they are.
    #   save_objects.each_slice(slice_size) do |objects|
    #     # attributes_for_saving
    #     batch_json = { "requests" => [] }
    #
    #     objects.each do |item|
    #       method ||= (item.new?) ? "POST" : "PATCH"
    #       object_path = "/1/#{item.class.model_name_uri}"
    #       object_path = "#{object_path}/#{item.id}" if item.id
    #       json = {
    #         "method" => method,
    #         "path" => object_path
    #       }
    #       json["body"] = item.attributes_for_saving unless method == "DELETE"
    #       batch_json["requests"] << json
    #     end
    #     res.post(batch_json.to_json, :content_type => "application/json") do |resp, req, res, &block|
    #       response = JSON.parse(resp) rescue nil
    #       if resp.code == 400
    #         return false
    #       end
    #       if response && response.is_a?(Array) && response.length == objects.length
    #         merge_all_attributes(objects, response) unless method == "DELETE"
    #       end
    #     end
    #   end
    #   true
    # end

    def self.merge_all_attributes(objects, response)
      objects.each_with_index do |item, index|
        next unless response[index]

        new_attributes = response[index].transform_keys { |key| key.underscore }
        item.merge_attributes(new_attributes)
      end

      true
    end

    # def self.save_all(objects)
    #   batch_save(objects)
    # end

    # def self.destroy_all(objects = nil)
    #   objects ||= self.all
    #   batch_save(objects, 20, "DELETE")
    # end

    # def self.delete_all(o)
    #   raise StandardError.new("delete_all doesn't exist. Did you mean destroy_all?")
    # end

    def self.bulk_import(new_objects, slice_size = 20)
      return [] if new_objects.blank?

      # Batch saves seem to fail if they're too big. We'll slice it up into multiple posts if they are.
      new_objects.each_slice(slice_size) do |objects|
        # attributes_for_saving
        batch_json = []

        objects.each do |item|
          unless item.new?
            raise StandardError,
                  'Bulk Import cannot only create records at the moment. It cannot update records'
          end

          batch_json << item.attributes_for_saving.transform_keys { |key| key.camelize(:lower) }
        end

        resp = resource.post('', body: batch_json)
        # TODO: attach errors if resp code is 400
        if resp.code != '200'
          # Error format in JSON
          #   "errors": {
          #     "[0].EmailAddress": [
          #       "The EmailAddress field is not a valid e-mail address."
          #     ]
          #   }
          if resp.code == '401'
            raise Lockstep::Exceptions::UnauthorizedError, 'Unauthorized: Check your App ID & Master Key'
          elsif resp.code == '400'
            raise Lockstep::Exceptions::BadRequestError, JSON.parse(resp.body)
          elsif resp.code == '404'
            raise Lockstep::Exceptions::RecordNotFound, 'Resource not found in the Platfrom'
          end
        end

        response = JSON.parse(resp.body)
        next unless response && response.is_a?(Array) && response.length == objects.length

        # return response.map { |item|
        #   Lockstep::Contact.new(item.transform_keys { |key| key.underscore }, false)
        # }
        merge_all_attributes(objects, response)
      end
      new_objects
    end

    # def self.load_settings
    #   @@settings ||= begin
    #                    path = "config/parse_resource.yml"
    #                    environment = defined?(Rails) && Rails.respond_to?(:env) ? Rails.env : ENV["RACK_ENV"]
    #                    if FileTest.exist? (path)
    #                      YAML.load(ERB.new(File.new(path).read).result)[environment]
    #                    elsif ENV["PARSE_RESOURCE_APPLICATION_ID"] && ENV["PARSE_RESOURCE_MASTER_KEY"]
    #                      settings = HashWithIndifferentAccess.new
    #                      settings['app_id'] = ENV["PARSE_RESOURCE_APPLICATION_ID"]
    #                      settings['master_key'] = ENV["PARSE_RESOURCE_MASTER_KEY"]
    #                      settings
    #                    else
    #                      raise "Cannot load parse_resource.yml and API keys are not set in environment"
    #                    end
    #                  end
    #   @@settings
    # end

    # Creates a RESTful resource for file uploads
    # sends requests to [base_uri]/files
    #
    # def self.upload(file_instance, filename, options={})
    #   load_settings
    #
    #   base_uri = "https://api.parse.com/1/files"
    #
    #   #refactor to settings['app_id'] etc
    #   app_id     = @@settings['app_id']
    #   master_key = @@settings['master_key']
    #
    #   options[:content_type] ||= 'image/jpg' # TODO: Guess mime type here.
    #   file_instance = File.new(file_instance, 'rb') if file_instance.is_a? String
    #
    #   filename = filename.parameterize
    #
    #   private_resource = RestClient::Resource.new "#{base_uri}/#{filename}", app_id, master_key
    #   private_resource.post(file_instance, options) do |resp, req, res, &block|
    #     return false if resp.code == 400
    #     return JSON.parse(resp) rescue {"code" => 0, "error" => "unknown error"}
    #   end
    #   false
    # end

    # Find a Lockstep::ApiRecord object by ID
    #
    # @param [String] id the ID of the Parse object you want to find.
    # @return [Lockstep::ApiRecord] an object that subclasses Lockstep::ApiRecord.
    def self.find(id)
      raise Lockstep::Exceptions::RecordNotFound, "Couldn't find #{name} without an ID" if id.blank?

      record = where(id_ref => id).first
      raise Lockstep::Exceptions::RecordNotFound, "Couldn't find #{name} with id: #{id}" if record.blank?

      record
    end

    # Find a Lockstep::ApiRecord object by given key/value pair
    #
    def self.find_by(*args)
      raise Lockstep::Exceptions::RecordNotFound, "Couldn't find an object without arguments" if args.blank?

      key, value = args.first.first
      unless valid_attribute?(key, raise_exception: true)
        raise StandardError, "Attribute '#{key}' has not been defined for #{name}"
      end

      where(key => value).first
    end

    # Find a Lockstep::ApiRecord object by chaining #where method calls.
    #
    def self.where(*args)
      query_builder.where(*args)
    end

    def self.additional_query_params(args)
      query_builder.additional_query_params(args)
    end

    def self.execute
      query_builder.execute
    end

    include Lockstep::QueryMethods

    def self.chunk(attribute)
      query_builder.chunk(attribute)
    end

    # Create a Lockstep::ApiRecord object.
    #
    # @param [Hash] attributes a `Hash` of attributes
    # @return [Lockstep::ApiRecord] an object that subclasses `Lockstep::ApiRecord`. Or returns `false` if object fails to save.
    def self.create(attributes = {})
      attributes = HashWithIndifferentAccess.new(attributes)
      obj = new(attributes)
      obj.save
      obj
    end

    # Replaced with a batch destroy_all method.
    # def self.destroy_all(all)
    #   all.each do |object|
    #     object.destroy
    #   end
    # end

    def self.class_attributes
      @class_attributes ||= {}
    end

    def self.valid_attribute?(key, raise_exception: false)
      # Valid only if the record is not an API record.
      # Default scopes build queries using ApiRecord to avoid conflicts. In this case, the query results in an
      # exception as the fields wouldn't have been defined in the ApiRecord
      return true if name == 'Lockstep::ApiRecord'

      attr = key.to_s
      Lockstep::Query::PREDICATES.keys.each do |predicate|
        if attr.end_with?(predicate)
          attr = attr.gsub(predicate, '')
          break
        end
      end
      valid = schema.has_key?(attr)
      raise StandardError, "Attribute '#{attr}' has not been defined for #{name}" if raise_exception && !valid

      valid
    end

    def persisted?
      if id
        true
      else
        false
      end
    end

    def new?
      !persisted?
    end

    # delegate from Class method
    def resource
      self.class.resource
    end

    # create RESTful resource for the specific Parse object
    # sends requests to [base_uri]/[classname]/[objectId]
    def instance_resource
      self.class.resource[id.to_s]
    end

    def pointerize(hash)
      new_hash = {}
      hash.each do |k, v|
        new_hash[k] = if v.respond_to?(:to_pointer)
                        v.to_pointer
                      elsif v.is_a?(Date) || v.is_a?(Time) || v.is_a?(DateTime)
                        self.class.to_date_object(v)
                      else
                        v
                      end
      end
      new_hash
    end

    def save
      if valid?
        run_callbacks :save do
          if new?
            create
          else
            update
          end
        end
      else
        false
      end
    rescue StandardError
      false
    end

    def create
      attrs = attributes_for_saving.transform_keys { |key| key.camelize(:lower) }
      resp = resource.post('', body: [attrs])
      result = post_result(resp)
    end

    def update(attributes = {})
      attributes = HashWithIndifferentAccess.new(attributes)

      @unsaved_attributes.merge!(attributes)
      # put_attrs = attributes_for_saving.to_json

      attrs = attributes_for_saving.transform_keys { |key| key.camelize(:lower) }
      resp = resource.patch(id, body: attrs)
      result = post_result(resp)
    end

    # Merges in the return value of a save and resets the unsaved_attributes
    def merge_attributes(results)
      results.transform_keys! { |key| key.underscore }
      @attributes.merge!(results)
      @attributes.merge!(@unsaved_attributes)

      merge_relations
      @unsaved_attributes = {}

      create_setters_and_getters!
      @attributes
    end

    def merge_relations
      # KK 11-17-2012 The response after creation does not return full description of
      # the object nor the relations it contains. Make another request here.
      # TODO: @@has_many_relations structure has been changed from array to hash, need to evaluate the impact here
      if has_many_relations.keys.map { |relation| relation.to_s.to_sym }
        # TODO: make this a little smarter by checking if there are any Pointer objects in the objects attributes.
        # @attributes = self.class.to_s.constantize.where(:objectId => @attributes[self.id_ref]).first.attributes
        @attributes = self.class.to_s.constantize.where(id_ref => @attributes[id_ref]).first.attributes
      end
    end

    def post_result(resp)
      if resp.code.to_s == '200' || resp.code.to_s == '201'
        body = JSON.parse(resp.body)
        # Create method always responds with an array, whereas update responds with the object
        body = body.first if body.is_a?(Array)

        merge_attributes(body)

        true
      elsif resp.code.to_s == '400'
        error_response = JSON.parse(resp.body)
        errors = error_response['errors']
        errors.each do |key, messages|
          attribute = key.split('.').last&.underscore
          messages.each do |message|
            self.errors.add attribute, ": #{message}"
          end
        end
      else
        error_response = JSON.parse(resp.body)
        pe = if error_response['error']
               Lockstep::Error.new(error_response['code'], error_response['error'])
             else
               Lockstep::Error.new(resp.code.to_s)
             end
        self.errors.add(pe.code.to_s.to_sym, pe.msg)
        error_instances << pe
        false
      end
    end

    def attributes_for_saving
      @unsaved_attributes = pointerize(@unsaved_attributes)
      put_attrs = @unsaved_attributes

      put_attrs = relations_for_saving(put_attrs)
      put_attrs.delete(id_ref)
      put_attrs.delete('created')
      put_attrs.delete('modified')
      put_attrs
    end

    def relations_for_saving(put_attrs)
      all_add_item_queries = {}
      all_remove_item_queries = {}
      @unsaved_attributes.each_pair do |key, value|
        next unless value.is_a? Array

        # Go through the array in unsaved and check if they are in array in attributes (saved stuff)
        add_item_ops = []
        @unsaved_attributes[key].each do |item|
          found_item_in_saved = false
          @attributes[key].each do |item_in_saved|
            if !!(defined? item.attributes) && item.attributes[id_ref] == item_in_saved.attributes[id_ref]
              found_item_in_saved = true
            end
          end

          next unless !found_item_in_saved && !!(defined? item.id)

          # need to send additem operation to parse
          put_attrs.delete(key) # arrays should not be sent along with REST to parse api
          add_item_ops << { '__type' => 'Pointer', 'className' => item.class.to_s, id_ref => item.id }
        end
        unless add_item_ops.empty?
          all_add_item_queries.merge!({ key => { '__op' => 'Add',
                                                 'objects' => add_item_ops } })
        end

        # Go through saved and if it isn't in unsaved perform a removeitem operation
        remove_item_ops = []
        unless @unsaved_attributes.empty?
          @attributes[key].each do |item|
            found_item_in_unsaved = false
            @unsaved_attributes[key].each do |item_in_unsaved|
              if !!(defined? item.attributes) && item.attributes[id_ref] == item_in_unsaved.attributes[id_ref]
                found_item_in_unsaved = true
              end
            end

            if !found_item_in_unsaved && !!(defined? item.id)
              # need to send removeitem operation to parse
              remove_item_ops << { '__type' => 'Pointer', 'className' => item.class.to_s, id_ref => item.id }
            end
          end
        end
        unless remove_item_ops.empty?
          all_remove_item_queries.merge!({ key => { '__op' => 'Remove',
                                                    'objects' => remove_item_ops } })
        end
      end

      # TODO: figure out a more elegant way to get this working. the remove_item merge overwrites the add.
      # Use a seperate query to add objects to the relation.
      # if !all_add_item_queries.empty?
      #  #result = self.instance_resource.put(all_add_item_queries.to_json, {:content_type => "application/json"}) do |resp, req, res, &block|
      #  #  return puts(resp, req, res, false, &block)
      #  #end
      #  puts result
      # end

      put_attrs.merge!(all_add_item_queries) unless all_add_item_queries.empty?
      put_attrs.merge!(all_remove_item_queries) unless all_remove_item_queries.empty?
      put_attrs
    end

    def update_attributes(attributes = {})
      update(attributes)
    end

    def update_attribute(key, value)
      send(key.to_s + '=', value)
      update
    end

    def destroy
      resp = resource.delete(id)
      if resp.code.to_s == '200'
        @attributes = {}
        @unsaved_attributes = {}
        return true
      end
      false
    end

    def reload
      return false if new?

      fresh_object = self.class.find(id)
      @attributes = {}
      @attributes.update(fresh_object.instance_variable_get('@attributes'))
      @unsaved_attributes = {}

      self
    end

    def dirty?
      @unsaved_attributes.length > 0
    end

    def clean?
      !dirty?
    end

    # provides access to @attributes for getting and setting
    def attributes
      @attributes ||= self.class.class_attributes
      @attributes
    end

    def attributes=(value)
      if value.is_a?(Hash) && value.present?
        value.each do |k, v|
          send "#{k}=", v
        end
      end
      @attributes
    end

    def get_attribute(k)
      attrs = @unsaved_attributes[k.to_s] ? @unsaved_attributes : @attributes
      case attrs[k]
      when Hash
        klass_name = attrs[k]['className']
        klass_name = 'User' if klass_name == '_User'
        case attrs[k]['__type']
        when 'Pointer'
          result = klass_name.to_s.constantize.find(attrs[k][id_ref])
        when 'Object'
          result = klass_name.to_s.constantize.new(attrs[k], false)
        when 'Date'
          result = DateTime.parse(attrs[k]['iso']).in_time_zone
        when 'File'
          result = attrs[k]['url']
        when 'Relation'
          objects_related_to_self = klass_name.constantize.where('$relatedTo' => {
            'object' => { '__type' => 'Pointer',
                          'className' => self.class.to_s, id_ref => id }, 'key' => k
          }).all
          attrs[k] = Lockstep::RelationArray.new self, objects_related_to_self, k, klass_name
          @unsaved_attributes[k] = Lockstep::RelationArray.new self, objects_related_to_self, k, klass_name
          result = @unsaved_attributes[k]
        end
      else
        # TODO: changed from @@has_many_relations to @@has_many_relations.keys as we have changed the has_many_relations
        #     from array to hash to capture more data points. Not sure of the impact of this.
        # relation will assign itself if an array, this will add to unsave_attributes
        if has_many_relations.keys.index(k.to_s)
          if attrs[k].nil?
            # result = nil
            result = load_association(:has_many, k)
          else
            @unsaved_attributes[k] = attrs[k].clone
            result = @unsaved_attributes[k]
          end
        elsif belongs_to_relations.keys.index(k.to_s)
          if attrs[k].nil?
            # result = nil
            result = load_association(:belongs_to, k)
          else
            @unsaved_attributes[k] = attrs[k].clone
            result = @unsaved_attributes[k]
          end
        else
          result = attrs[k.to_s]
        end
      end
      result
    end

    # Alias of get_attribute
    def _read_attribute(attr)
      get_attribute(attr)
    end

    def set_attribute(k, v)
      if v.is_a?(Date) || v.is_a?(Time) || v.is_a?(DateTime)
        v = self.class.to_date_object(v)
        # elsif v.respond_to?(:to_pointer)
        #   v = v.to_pointer
      elsif (type = schema[k])
        # Typecast the result value using dry-types
        v = type[v]
      elsif v.present? and (enum = enum_config[k]).present? and enum.keys.include?(v.to_s)
        v = enum[v]
      end

      @unsaved_attributes[k.to_s] = v unless v == @attributes[k.to_s] # || @unsaved_attributes[k.to_s]
      @attributes[k.to_s] = v
      v
    end

    def self.has_many_relations
      @has_many_relations ||= {}.with_indifferent_access
    end

    def has_many_relations
      self.class.has_many_relations
    end

    # Alias for has_many_relations
    def self.lockstep_has_many_relations
      has_many_relations
    end

    def self.belongs_to_relations
      @belongs_to_relations ||= {}.with_indifferent_access
    end

    def belongs_to_relations
      self.class.belongs_to_relations
    end

    # Alias for belongs_to_relations
    def self.lockstep_belongs_to_relations
      belongs_to_relations
    end

    def primary_key
      id_ref
    end

    # aliasing for idiomatic Ruby
    def id
      get_attribute(id_ref)
    rescue StandardError
      nil
    end

    def objectId
      get_attribute(id_ref)
    rescue StandardError
      nil
    end

    def created_at
      get_attribute('created')
    end

    def updated_at
      get_attribute('modified')
    end

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
    end

    # if we are comparing objects, use id if they are both Lockstep::ApiRecord objects
    def ==(other)
      if other.class <= Lockstep::ApiRecord
        id == other.id
      else
        super
      end
    end

    def load_association(association_type, relation)
      @loaded_associations ||= []
      return nil if @loaded_associations.include?(relation)

      @loaded_associations << relation # Prevent the load_association from being called the 2nd time

      val = nil
      case association_type
      when :has_many
        relation_config = has_many_relations[relation]

        if relation_config[:loader].present?
          val = relation_config[:loader].call(self)
        else
          return val unless relation_config[:foreign_key].present? and relation_config[:primary_key].present?

          relation_klass = relation_config[:class_name].constantize
          return val unless relation_klass.model_name_uri.present?

          query = { relation_config[:foreign_key] => send(relation_config[:primary_key]) }
          if relation_config[:polymorphic]
            polymorphic_config = Lockstep::RelationArray.has_many_polymorphic_attributes(self,
                                                                                         relation_config[:polymorphic])
            query.merge!(polymorphic_config)
          end
          related_objects = relation_klass.send(:where, query).execute
          val = Lockstep::RelationArray.new self, related_objects, relation, relation_config[:class_name]
        end
      when :belongs_to
        relation_config = belongs_to_relations[relation]
        if relation_config[:loader].present?
          val = relation_config[:loader].call(self)
        else
          val = relation_config[:class_name].constantize.send(:find_by,
                                                              relation_config[:primary_key] => send(relation_config[:foreign_key]))
        end
      end

      set_attribute(relation, val)
      val
    end

    # @has_many_associations polymorphic properties builder.
    # Polymorphic properties is used to further scope down the has_many association while querying or creating
    #
    # def has_many_polymorphic_attributes(polymorphic_config)
    #   return polymorphic_config if polymorphic_config.is_a?(Hash)
    #   return polymorphic_config.call(self) if polymorphic_config.is_a?(Proc)
    #
    #   nil
    # end

    # TODO: Implement the ability to build_belongs_to_association
    #       Challenge is that it has to update the record's association_id once the new association is created
    # def build_belongs_to_association(parent, attributes_hash)
    #   if (val = get_attribute(parent)).present?
    #     return val
    #   end
    #
    #   relation_config = @@belongs_to_relations[parent]
    #   # Assign the parent records primary_key to the foreign_key of the association
    #   foreign_key = relation_config[:foreign_key]
    #   primary_key = relation_config[:primary_key]
    #   attributes_hash[primary_key] = delegate.send(foreign_key)
    #   # TODO implement polymorphic association support
    #   object = self.class_name.constantize.new(attributes_hash)
    #   set_attribute(parent, object)
    #
    #   object
    # end

    # Enum implementation - Start
    def self.enum_config
      @enum_config ||= {}.with_indifferent_access
    end

    def enum_config
      self.class.enum_config
    end

    def self.enum(config)
      config.each do |attribute, values|
        # Standardise values to hash
        if values.is_a?(Array)
          value_map = {}.with_indifferent_access
          values.each { |item| value_map[item] = item }
        elsif values.is_a?(Hash)
          value_map = values.with_indifferent_access
        else
          raise StandardError, "Invalid values for enum #{attribute}"
        end

        # Convert values to string if the value is symbol
        value_map.each { |k, v| value_map[k] = v.to_s if v.is_a?(Symbol) }

        enum_config[attribute] = value_map
        class_eval do
          value_map.each do |k, v|
            define_method("#{k}!") do
              set_attribute(attribute, v)
              return save if persisted?

              true
            end

            define_method("#{k}?") do
              get_attribute(attribute) == v
            end
          end
        end
      end
    end

    def validate_enum
      enum_config.each do |attribute, values_map|
        value = get_attribute(attribute)
        next if value.nil?

        errors.add attribute, 'has an invalid value' unless values_map.values.include?(value)
      end
    end

    def self.single_record!
      define_singleton_method :record do
        resp = resource.get('')

        return [] if %w(404).include?(resp.code.to_s)
        # TODO handle non 200 response code. Throwing an exception for now
        raise StandardError.new("#{resp.code} error while fetching: #{resp.body}") unless %w(201 200).include?(resp.code.to_s)

        result = JSON.parse(resp.body)
        r = result.transform_keys { |key| key.underscore }
        model_name.to_s.constantize.new(r, false)
      end
    end

    # Enum implementation - End

    def self.alias_attribute(new_name, old_name)
      define_method(new_name) do
        send(old_name)
      end

      define_method("#{new_name}=") do |value|
        send("#{old_name}=", value)
      end
    end

    def to_json(options = {})
      as_json(options).to_json
    end

    def as_json(_options = {})
      @attributes.merge(@unsaved_attributes).as_json
    end
  end
end
