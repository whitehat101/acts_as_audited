require 'set'

# Audit saves the changes to ActiveRecord models.  It has the following attributes:
#
# * <tt>auditable</tt>: the ActiveRecord model that was changed
# * <tt>user</tt>: the user that performed the change; a string or an ActiveRecord model
# * <tt>action</tt>: one of create, update, or delete
# * <tt>audited_changes</tt>: a serialized hash of all the changes
# * <tt>comment</tt>: a comment set with the audit
# * <tt>created_at</tt>: Time that the change was performed
#
class Audit < ActiveRecord::Base
  belongs_to :auditable, :polymorphic => true
  belongs_to :user, :polymorphic => true
  belongs_to :associated, :polymorphic => true

  before_create :set_version_number, :set_audit_user, :set_audit_group

  serialize :audited_changes

  cattr_accessor :audited_class_names
  self.audited_class_names = Set.new

  # Order by ver
  default_scope order(:version)
  scope :descending, reorder("version DESC")

  class << self

    # Returns the list of classes that are being audited
    def audited_classes
      audited_class_names.map(&:constantize)
    end

    # All audits made during the block called will be recorded as made
    # by +user+. This method is hopefully threadsafe, making it ideal
    # for background operations that require audit information.
    def as_user(user, &block)
      Thread.current[:acts_as_audited_user] = user

      yieldval = yield

      Thread.current[:acts_as_audited_user] = nil

      yieldval
    end

    # All audits made during the block get the same +tag+ and +comment+.
    def as_group(tag = nil, comment = nil, &block)
      Thread.current[:acts_as_audited_tag] = tag
      Thread.current[:acts_as_audited_comment] = comment

      yieldval = yield

      Thread.current[:acts_as_audited_tag] = nil
      Thread.current[:acts_as_audited_comment] = nil

      yieldval
    end

    # @private
    def reconstruct_attributes(audits)
      attributes = {}
      result = audits.collect do |audit|
        attributes.merge!(audit.new_attributes).merge!(:version => audit.version)
        yield attributes if block_given?
      end
      block_given? ? result : attributes
    end

    # @private
    def assign_revision_attributes(record, attributes)
      attributes.each do |attr, val|
        record = record.dup if record.frozen?

        if record.respond_to?("#{attr}=")
          record.attributes.has_key?(attr.to_s) ?
            record[attr] = val :
            record.send("#{attr}=", val)
        end
      end
      record
    end

  end

  # Allows user to be set to either a string or an ActiveRecord object
  # @private
  def user_as_string=(user)
    # reset both either way
    self.user_as_model = self.username = nil
    user.is_a?(ActiveRecord::Base) ?
      self.user_as_model = user :
      self.username = user
  end
  alias_method :user_as_model=, :user=
  alias_method :user=, :user_as_string=

  # @private
  def user_as_string
    self.user_as_model || self.username
  end
  alias_method :user_as_model, :user
  alias_method :user, :user_as_string

  # Return an instance of what the object looked like at this revision. If
  # the object has been destroyed, this will be a new record.
  def revision
    clazz = auditable_type.constantize
    ( clazz.find_by_id(auditable_id) || clazz.new ).tap do |m|
      Audit.assign_revision_attributes(m, self.class.reconstruct_attributes(ancestors).merge({:version => version}))
    end
  end

  # Return all audits older than the current one.
  def ancestors
    self.class.where(['auditable_id = ? and auditable_type = ? and version <= ?',
      auditable_id, auditable_type, version])
  end

  # Returns a hash of the changed attributes with the new values
  def new_attributes
    (audited_changes || {}).inject({}.with_indifferent_access) do |attrs,(attr,values)|
      attrs[attr] = values.is_a?(Array) ? values.last : values
      attrs
    end
  end

  # Returns a hash of the changed attributes with the old values
  def old_attributes
    (audited_changes || {}).inject({}.with_indifferent_access) do |attrs,(attr,values)|
      attrs[attr] = Array(values).first
      attrs
    end
  end

private

  def set_version_number
    max = self.class.maximum(:version,
      :conditions => {
        :auditable_id => auditable_id,
        :auditable_type => auditable_type
      }) || 0
    self.version = max + 1
  end

  def set_audit_user
    self.user = Thread.current[:acts_as_audited_user] if Thread.current[:acts_as_audited_user]
    nil # prevent stopping callback chains
  end

  def set_audit_group
    self.tag = Thread.current[:acts_as_audited_tag] if Thread.current[:acts_as_audited_tag]
    self.comment = Thread.current[:acts_as_audited_comment] if Thread.current[:acts_as_audited_comment]
    nil # prevent stopping callback chains
  end
end
