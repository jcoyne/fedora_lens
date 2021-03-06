require 'rdf'
require 'ldp'
require 'ldp_monkeypatch'
require 'rdf/turtle'
require 'nokogiri'
require 'active_model'
require 'active_support/concern'
require 'active_support/core_ext/object'
require 'active_support/core_ext/class/attribute'
require 'active_support/core_ext/module/attribute_accessors'
require 'active_support/core_ext/hash'
require 'fedora_lens/errors'

module FedoraLens
  extend ActiveSupport::Concern
  HOST = "http://localhost:8080"
  mattr_accessor :connection

  included do
    extend ActiveModel::Naming
    include ActiveModel::Validations
    include ActiveModel::Conversion

    class_attribute :defined_attributes
    self.defined_attributes = {}.with_indifferent_access

    attr_reader :attributes
    attr_reader :orm

    def initialize(data = {})
      if data.is_a? Hash
        @attributes = data.with_indifferent_access
      elsif data.is_a? Ldp::Resource
        @orm = Ldp::Orm.new(data)
        @attributes = get_attributes_from_orm(@orm)
      else
        raise ArgumentError, "Argument must be a Hash or Ldp::Resource"
      end
    end
  end

  def persisted?()      false end

  def errors
    obj = Object.new
    def obj.[](key)         [] end
    def obj.full_messages() [] end
    obj
  end

  def read_attribute_for_validation(key)
    @attributes[key]
  end

  def reload
    @orm = @orm.reload
    @attributes = get_attributes_from_orm(@orm)
  end

  # FIXME this doesn't seem to return false on a save failure
  def save
    @orm = self.class.orm_to_hash[:put].call(@orm, @attributes)
    # Fedora errors out when you try to set the rdf:type
    # see https://github.com/cbeer/ldp/issues/2
    @orm.graph.delete([@orm.resource.subject_uri,
                       RDF::URI.new("http://www.w3.org/1999/02/22-rdf-syntax-ns#type"),
                       nil])
    @orm.save
    @orm.last_response.success?
  end

  def save!
    save || raise(RecordNotSaved)
  end

  private

  def get_attributes_from_orm(orm)
    self.class.orm_to_hash[:get].call(orm).with_indifferent_access
  end

  module ClassMethods
    def find(id)
      FedoraLens.connection ||= Ldp::Client.new(HOST)
      resource = Ldp::Resource.new(FedoraLens.connection, HOST + id)
      self.new(resource)
    end

    def attribute(name, path, options={})
      defined_attributes[name] = path.map{|s| coerce_to_lens(s)}
      define_method name do
        @attributes[name]
      end
      define_method "#{name}=" do |value|
        @attributes[name] = value
      end
      orm_to_hash = nil # force us to rebuild the aggregate_lens in case it was already built.
    end

    def orm_to_hash
      if @orm_to_hash.nil?
        aggregate_lens = defined_attributes.reduce({}) do |acc, pair|
          name, path = pair
          lens = path.reduce{|outer, inner| Lenses.compose(outer, inner)}
          acc.merge(name => lens)
        end
        @orm_to_hash = Lenses.orm_to_hash(aggregate_lens)
      end
      @orm_to_hash
    end

    def coerce_to_lens(path_segment)
      if path_segment.is_a? RDF::URI
        Lenses.get_predicate(path_segment)
      else
        path_segment
      end
    end

    # def has_one(name, scope = nil, options = {})
    #   ActiveRecord::Associations::Builder::HasOne.build(self, name, scope, options)
    # end
  end
end

require 'fedora_lens/lenses'
class TestRelated
  include FedoraLens
  include FedoraLens::Lenses
  attribute :title, [RDF::DC11.title, Lenses.single, Lenses.literal_to_string]
end

class TestClass
  include FedoraLens
  include FedoraLens::Lenses
  attribute :title, [RDF::DC11.title, Lenses.single, Lenses.literal_to_string]
  attribute :mixinTypes, [
    RDF::URI.new("http://fedora.info/definitions/v4/repository#mixinTypes")]
  attribute :primaryType, [
    RDF::URI.new("http://fedora.info/definitions/v4/repository#primaryType"),
    Lenses.single,
    Lenses.literal_to_string]
  attribute :primary_id, [
    RDF::DC11.relation,
    Lenses.single,
    Lenses.literal_to_string,
    Lenses.as_dom,
    Lenses.at_css("relationship[type=primary]")]
  attribute :secondary, [
    RDF::DC11.relation,
    Lenses.single,
    Lenses.literal_to_string,
    Lenses.as_dom,
    Lenses.at_css("relationship[type=secondary]"),
    # Lenses.load_model(TestRelated)
    ]
  # def self.generated_feature_methods
  # end
  # has_one :primary
end
