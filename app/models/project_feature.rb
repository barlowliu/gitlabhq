# frozen_string_literal: true

class ProjectFeature < ActiveRecord::Base
  # == Project features permissions
  #
  # Grants access level to project tools
  #
  # Tools can be enabled only for users, everyone or disabled
  # Access control is made only for non private projects
  #
  # levels:
  #
  # Disabled: not enabled for anyone
  # Private:  enabled only for team members
  # Enabled:  enabled for everyone able to access the project
  # Public:   enabled for everyone (only allowed for pages)
  #

  # Permission levels
  DISABLED = 0
  PRIVATE  = 10
  ENABLED  = 20
  PUBLIC   = 30

  FEATURES = %i(issues merge_requests wiki snippets builds repository pages).freeze

  class << self
    def access_level_attribute(feature)
      feature = feature.model_name.plural.to_sym if feature.respond_to?(:model_name)
      raise ArgumentError, "invalid project feature: #{feature}" unless FEATURES.include?(feature)

      "#{feature}_access_level".to_sym
    end

    def quoted_access_level_column(feature)
      attribute = connection.quote_column_name(access_level_attribute(feature))
      table = connection.quote_table_name(table_name)

      "#{table}.#{attribute}"
    end
  end

  # Default scopes force us to unscope here since a service may need to check
  # permissions for a project in pending_delete
  # http://stackoverflow.com/questions/1540645/how-to-disable-default-scope-for-a-belongs-to
  belongs_to :project, -> { unscope(where: :pending_delete) }

  validates :project, presence: true

  validate :repository_children_level
  validate :allowed_access_levels

  default_value_for :builds_access_level,         value: ENABLED, allows_nil: false
  default_value_for :issues_access_level,         value: ENABLED, allows_nil: false
  default_value_for :merge_requests_access_level, value: ENABLED, allows_nil: false
  default_value_for :snippets_access_level,       value: ENABLED, allows_nil: false
  default_value_for :wiki_access_level,           value: ENABLED, allows_nil: false
  default_value_for :repository_access_level,     value: ENABLED, allows_nil: false

  def feature_available?(feature, user)
    # This feature might not be behind a feature flag at all, so default to true
    return false unless ::Feature.enabled?(feature, user, default_enabled: true)

    get_permission(user, access_level(feature))
  end

  def access_level(feature)
    public_send(ProjectFeature.access_level_attribute(feature)) # rubocop:disable GitlabSecurity/PublicSend
  end

  def builds_enabled?
    builds_access_level > DISABLED
  end

  def wiki_enabled?
    wiki_access_level > DISABLED
  end

  def merge_requests_enabled?
    merge_requests_access_level > DISABLED
  end

  def issues_enabled?
    issues_access_level > DISABLED
  end

  def pages_enabled?
    pages_access_level > DISABLED
  end

  def public_pages?
    return true unless Gitlab.config.pages.access_control

    pages_access_level == PUBLIC || pages_access_level == ENABLED && project.public?
  end

  private

  # Validates builds and merge requests access level
  # which cannot be higher than repository access level
  def repository_children_level
    validator = lambda do |field|
      level = public_send(field) || ProjectFeature::ENABLED # rubocop:disable GitlabSecurity/PublicSend
      not_allowed = level > repository_access_level
      self.errors.add(field, "cannot have higher visibility level than repository access level") if not_allowed
    end

    %i(merge_requests_access_level builds_access_level).each(&validator)
  end

  # Validates access level for other than pages cannot be PUBLIC
  def allowed_access_levels
    validator = lambda do |field|
      level = public_send(field) || ProjectFeature::ENABLED # rubocop:disable GitlabSecurity/PublicSend
      not_allowed = level > ProjectFeature::ENABLED
      self.errors.add(field, "cannot have public visibility level") if not_allowed
    end

    (FEATURES - %i(pages)).each {|f| validator.call("#{f}_access_level")}
  end

  def get_permission(user, level)
    case level
    when DISABLED
      false
    when PRIVATE
      user && (project.team.member?(user) || user.full_private_access?)
    when ENABLED
      true
    when PUBLIC
      true
    else
      true
    end
  end
end
