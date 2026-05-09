# frozen_string_literal: true

class ListComponent < ::ViewComponent::Base
  def initialize(items: nil)
    @items = items
  end
end
