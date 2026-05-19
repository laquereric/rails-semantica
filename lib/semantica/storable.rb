# frozen_string_literal: true

module Semantica
  # PLAN 0.29.1 Phase D — per-model triple-emission DSL. ActiveRecord
  # concern that takes a `triples do ... end` block declaring
  # subject + per-predicate value lambdas; hooks after_save +
  # after_destroy to emit / retract triples via Semantica::Sparql.
  # Stub-only in Phase A.
  module Storable
    extend ActiveSupport::Concern if defined?(ActiveSupport::Concern)

    class_methods do
      def triples(&_block)
        raise NotImplementedError, "Semantica::Storable.triples ships in PLAN_0_29_1 Phase D"
      end
    end
  end
end
