# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. This slice runs the test suite
  # PRODUCTION-LIKE on purpose: eager_load is forced TRUE so the whole app (every
  # model, the Capsule protocol, the AdversarialService) is loaded up front, exactly
  # as a booted production process would be — not lazily per-test. This is the point
  # of reviewer item #16: prove the protocol holds inside a genuinely booted Rails env.
  config.eager_load = true

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true

  # A REAL cache store (not :null_store), so Rails.cache.write/read in the
  # AdversarialService raw path exercises a genuine cache, and so the Ractor test can
  # observe what happens when a real ActiveSupport::Cache::MemoryStore is touched off
  # the main Ractor.
  config.cache_store = :memory_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
