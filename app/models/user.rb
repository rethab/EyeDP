# frozen_string_literal: true

# == Schema Information
#
# Table name: users
#
#  id                     :uuid             not null, primary key
#  current_sign_in_at     :datetime
#  current_sign_in_ip     :inet
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  last_sign_in_at        :datetime
#  last_sign_in_ip        :inet
#  remember_created_at    :datetime
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  sign_in_count          :integer          default(0), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#
# Indexes
#
#  index_users_on_email                 (email) UNIQUE
#  index_users_on_reset_password_token  (reset_password_token) UNIQUE
#

class User < ApplicationRecord # rubocop:disable Metrics/ClassLength
  extend Notifiable
  include Notifiable

  audited

  has_many :emails, dependent: :destroy

  alias_attribute :real_name, :name

  devise :two_factor_authenticatable,
         otp_secret_encryption_key: ENV['TOTP_ENCRYPTION_KEY']

  devise :two_factor_backupable, otp_number_of_backup_codes: 10

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  # :rememberable
  devise :registerable, # :recoverable,
         :fido_usf_registerable, :timeoutable

  devise :multi_email_authenticatable,
         :multi_email_recoverable, :multi_email_confirmable

  devise :expirable

  has_many :user_groups, dependent: :destroy
  has_many :groups, through: :user_groups, dependent: :destroy
  has_many :group_permissions, through: :groups
  has_many :permissions, through: :group_permissions

  has_many :access_grants,
           class_name: 'Doorkeeper::AccessGrant',
           foreign_key: :resource_owner_id,
           dependent: :delete_all # or :destroy if you need callbacks

  has_many :access_tokens,
           class_name: 'Doorkeeper::AccessToken',
           foreign_key: :resource_owner_id,
           dependent: :delete_all # or :destroy if you need callbacks

  has_many :logins, dependent: :destroy

  has_many :custom_userdata, dependent: :destroy

  validates :username, presence: true, uniqueness: { case_sensitive: false } # rubocop:disable Rails/UniqueValidationWithoutIndex

  validate :validate_username

  before_validation :ensure_password

  notify_for %i[create update destroy], check: :notify_if

  def notify_if
    saved_changes.keys.reject do |k|
      %w[updated_at last_activity_at].include?(k)
    end.any?
  end

  def notification_attributes
    {
      username: username,
      email: email
    }
  end

  attr_writer :login

  def validate_username
    errors.add(:username, :invalid) if User.joins(:emails).exists?(emails: { address: username })
  end

  def force_password_reset!
    new_pass = SecureRandom.hex(32)
    update({ password: new_pass, password_confirmation: new_pass })

    token = set_reset_password_token
    passed = true
    emails.confirmed.each do |email|
      passed = false unless UserMailer.force_reset_password_email(self, token, email.address).deliver_later
    end
    passed
  end

  def send_admin_welcome_email
    token = set_reset_password_token
    emails.confirmed.each do |email|
      UserMailer.admin_welcome_email(self, token, email.address).deliver_later
    end
  end

  def primary_email
    primary_email_record.try(:address)
  end

  def confirmed?(address = nil)
    if address.nil?
      !!primary_email_record.confirmed_at
    else
      !!address.confirmed_at
    end
  end

  def confirm!
    primary_email_record.update!({ confirmed_at: Time.zone.now })
  end

  def self.u2f_authenticate(user, app_id, json_response, challenges)
    response = U2F::SignResponse.load_from_json(json_response)
    registration = user.fido_usf_devices
                       .find_by(key_handle: response.key_handle)
    u2f = U2F::U2F.new(app_id)
    return false unless registration

    u2f.authenticate!(challenges, response, registration.public_key, registration.counter)
    registration.update(counter: response.counter)
    true
  rescue JSON::ParserError, NoMethodError, ArgumentError, U2F::Error
    false
  end

  def disable_two_factor!(otp_only = false) # rubocop:disable Style/OptionalBooleanParameter
    transaction do
      update(
        otp_required_for_login:      false,
        encrypted_otp_secret:        nil,
        encrypted_otp_secret_iv:     nil,
        encrypted_otp_secret_salt:   nil,
        otp_backup_codes:            nil
      )
      fido_usf_devices.destroy_all unless otp_only
    end
  end

  def asserted_attributes # rubocop:disable Metrics/MethodLength
    {
      groups: { getter: :asserted_groups },
      email: {
        getter: :email,
          name_format: Saml::XML::Namespaces::Formats::NameId::EMAIL_ADDRESS,
          name_id_format: Saml::XML::Namespaces::Formats::NameId::EMAIL_ADDRESS
      },
      username: {
        getter: :username
        # name_format: Saml::XML::Namespaces::Formats::NameId::USERNAME,
        # name_id_format: Saml::XML::Namespaces::Formats::NameId::USERNAME
      },
      name: {
        getter: :name
        # name_format: Saml::XML::Namespaces::Formats::NameId::NAME,
        # name_id_format: Saml::XML::Namespaces::Formats::NameId::NAME
      }
    }
  end

  def asserted_groups
    if two_factor_enabled?
      groups
    else
      groups.where(requires_2fa: false)
    end
  end

  def inactive_message
    expired? ? :user_expired : super
  end

  def admin?
    roles.include?(:admin)
  end

  def manager?
    roles.include?(:manager)
  end

  def operator?
    roles.include?(:operator)
  end

  def to_s
    username || email
  end
  # def groups
  #   %i[awesome internal]
  # end

  def roles
    asserted_groups.map(&:roles).flatten.uniq
  end

  def login
    @login || username || email
  end

  def self.by_id_and_login(id, login)
    where(id: id).database_authentication_rel({ login: login })
  end

  def self.database_authentication_rel(conditions)
    if (login = conditions.delete(:login))
      database_auth_rel_with_login(login, conditions)
    elsif conditions.key?(:email)
      database_auth_rel_with_email(conditions)
    elsif conditions.key?(:username)
      where(conditions.to_h)
    else
      super
    end
  end

  def self.database_auth_rel_with_login(login, conditions)
    joins(:emails)
      .where(conditions.to_h)
      .where(['lower(username) = :value OR lower("emails"."address") = :value', { value: login.downcase }])
      .where.not(emails: { confirmed_at: nil })
  end

  def self.database_auth_rel_with_email(conditions)
    email = conditions.delete(:email)
    joins(:emails)
      .where(conditions.to_h)
      .where(['lower("emails"."address") = :value', { value: email.downcase }])
      .where.not(emails: { confirmed_at: nil })
  end

  def self.find_for_database_authentication(warden_conditions)
    conditions = warden_conditions.dup
    database_authentication_rel(conditions).first
  end

  def two_factor_enabled?
    two_factor_otp_enabled? || two_factor_u2f_enabled?
  end

  def two_factor_otp_enabled?
    otp_required_for_login?
  end

  def two_factor_u2f_enabled?
    if fido_usf_devices.loaded?
      fido_usf_devices.any?
    else
      fido_usf_devices.exists?
    end
  end

  private

  def ensure_password
    self.password = SecureRandom.hex(32) if encrypted_password.blank?
  end
end
