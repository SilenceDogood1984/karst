# frozen_string_literal: true

# Experimental projection only: deliberately outside lib/ and all public outputs.
# Input must be a Reproduction::Observation, not a record or a source-code guess.
class QualificationContractSpike
  def self.build(observation)
    new(observation).document
  end

  def initialize(observation)
    @observation = observation
  end

  # rubocop:disable Metrics/MethodLength
  def document
    {
      schema: "karst.qualification.spike.v1",
      target: { method: @observation.http_method, route_pattern: nil,
                controller: @observation.controller, action: @observation.action },
      identity: identity,
      behavior: behavior,
      predicates: [],
      unknowns: [
        { question: "What application state qualified this behavior?",
          reason: "Karst observed the outcome but not the deciding model predicate" },
        { question: "What route pattern handled this request?",
          reason: "The observation contains path parameters, not an observed route pattern" }
      ] + identity_unknowns
    }
  end
  # rubocop:enable Metrics/MethodLength

  private

  def identity
    evidence = @observation.identity
    {
      requested: principal(evidence.requested), resolved: principal(evidence.observed),
      confirmation: evidence.confirmation.to_s, confirmed: evidence.confirmed?,
      observed_at: evidence.observed_at&.to_s, source: evidence.observation_source&.to_s,
      changed_during_request: evidence.changed_during_request
    }
  end

  def principal(value)
    return nil unless value

    { model: value.model_name.to_s, id: value.id.is_a?(Integer) ? value.id : value.id.to_s }
  end

  def identity_unknowns
    return [] unless @observation.identity.confirmation == :unobservable

    [{ question: "Which principal did the application resolve?",
       reason: "Runtime identity was unobservable; requested identity is intent only" }]
  end

  def behavior
    {
      status: @observation.status, controller_completed: @observation.controller_completed,
      redirected: !@observation.redirect.nil?,
      halted_callback: callback_name, exception_class: @observation.exception_class,
      exception_phase: @observation.exception_phase,
      rendered: @observation.rendered.map { |item| item.slice(:virtual_path, :completed) }
    }
  end

  # Do not export a Proc's inspect string, source path, or arbitrary error text.
  def callback_name
    name = @observation.halted_callback
    return nil unless name

    name.match?(/\A[a-zA-Z_]\w*[!?=]?\z/) ? name : "[opaque callback]"
  end
end

# Documentation-level representability, not a Body Double adapter or execution
# plan. Capabilities must come from a separately inspected construction catalog.
class QualificationConstructionReport
  def self.classify(predicate, exact_attributes: [], named_states: [])
    return "not representable" unless predicate[:basis] == "observed" && predicate[:evidence_ref]

    key = [predicate[:subject], predicate[:path], predicate[:operator], predicate[:value]]
    return "directly representable" if predicate[:operator] == "eq" && exact_attributes.include?(key.first(2))
    return "requires named construction vocabulary" if named_states.include?(key)

    "not representable"
  end

  def self.rows(contract, **capabilities)
    contract.fetch(:predicates).map do |predicate|
      { predicate: predicate, representation: classify(predicate, **capabilities) }
    end
  end
end
