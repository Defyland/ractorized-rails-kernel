# frozen_string_literal: true

class OutboxEvent < ApplicationRecord
  scope :unpublished, -> { where(published_at: nil) }
end
