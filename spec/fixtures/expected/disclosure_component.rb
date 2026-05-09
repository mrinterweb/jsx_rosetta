# frozen_string_literal: true

class DisclosureComponent < ::ViewComponent::Base
  def initialize(summary: nil, open: false)
    @summary = summary
    @open = open
  end
end
