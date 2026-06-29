# frozen_string_literal: true

# Boot proof: run with the FULL Rails environment loaded, e.g.
#   RAILS_ENV=test bundle exec ruby script/boot_proof.rb
# Prints concrete evidence that this is a genuinely booted Rails app (not standalone AR):
# the Rails version, env, application class, whether eager_load is on for this run, and the
# REAL classes behind Rails.cache and Rails.logger.
require_relative "../config/environment"

puts "Rails.version                 = #{Rails.version}"
puts "Rails.env                     = #{Rails.env}"
puts "Rails.application.class        = #{Rails.application.class}"
puts "config.eager_load             = #{Rails.application.config.eager_load}"
puts "Rails.cache.class             = #{Rails.cache.class}"
puts "Rails.logger.class            = #{Rails.logger.class}"
puts "Current ancestors include CA  = #{Current.ancestors.include?(ActiveSupport::CurrentAttributes)}"
puts "DB current_database           = #{ActiveRecord::Base.connection.execute('select current_database()').first['current_database']}"
puts "Capsule eager-loaded?         = #{defined?(Capsule) ? 'yes' : 'no'}"
puts "AdversarialService loaded?    = #{defined?(AdversarialService) ? 'yes' : 'no'}"
