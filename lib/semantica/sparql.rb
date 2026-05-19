# frozen_string_literal: true

module Semantica
  # PLAN 0.29.1 Phase C — SPARQL facade. Three class methods
  # (select / ask / construct), all returning structured envelopes
  # ({ ok:, results:/value:/ntriples: } on success, { ok: false,
  # reason:, because: } on failure). Never raises. Stub-only in
  # Phase A.
  module Sparql
    module_function

    def select(_query)
      raise NotImplementedError, "Semantica::Sparql.select ships in PLAN_0_29_1 Phase C"
    end

    def ask(_query)
      raise NotImplementedError, "Semantica::Sparql.ask ships in PLAN_0_29_1 Phase C"
    end

    def construct(_query)
      raise NotImplementedError, "Semantica::Sparql.construct ships in PLAN_0_29_1 Phase C"
    end
  end
end
