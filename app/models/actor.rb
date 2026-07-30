class Actor < ApplicationRecord
  has_many :push_events, dependent: :nullify

  validates :github_id, presence: true, uniqueness: true
  validates :api_url, presence: true
  validate :raw_payload_must_be_an_object

  private

  def raw_payload_must_be_an_object
    errors.add(:raw_payload, "must be a JSON object") unless raw_payload.is_a?(Hash)
  end
end
