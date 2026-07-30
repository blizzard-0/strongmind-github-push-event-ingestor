class PushEvent < ApplicationRecord
  belongs_to :actor, optional: true
  belongs_to :repository, optional: true

  validates :github_event_id, presence: true, uniqueness: true
  validates :repository_github_id, :push_id, :ref, :head, :before, presence: true
  validate :raw_payload_must_be_an_object

  private

  def raw_payload_must_be_an_object
    errors.add(:raw_payload, "must be a JSON object") unless raw_payload.is_a?(Hash)
  end
end
