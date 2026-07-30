class PushEventSerializer
  def initialize(push_event)
    @push_event = push_event
  end

  def collection
    {
      id: push_event.id,
      github_event_id: push_event.github_event_id,
      repository_github_id: push_event.repository_github_id,
      push_id: push_event.push_id,
      ref: push_event.ref,
      head: push_event.head,
      before: push_event.before,
      github_created_at: timestamp(push_event.github_created_at),
      created_at: timestamp(push_event.created_at),
      actor: actor_summary,
      repository: repository_summary
    }
  end

  def detail
    collection.merge(raw_payload: push_event.raw_payload)
  end

  private

  attr_reader :push_event

  def actor_summary
    return unless push_event.actor

    {
      github_id: push_event.actor.github_id,
      login: push_event.actor.login
    }
  end

  def repository_summary
    return unless push_event.repository

    {
      github_id: push_event.repository.github_id,
      name: push_event.repository.name
    }
  end

  def timestamp(value)
    value&.iso8601(3)
  end
end
