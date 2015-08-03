# encoding: utf-8
require "logstash/environment"
require "logstash/errors"
require "logstash/pipeline"
require "uri"
LogStash::Environment.load_locale!

# future interface
#  start -> start all pipelines
#  stop -> stop all pipelines
#  add_pipeline(key, config, opts) -> add a pipeline
#  remove_pipeline(key) -> remove a pipeline
#  get_pipeline(key) -> get a pipeline

class LogStash::Agent

  attr_writer :logger

  def initialize
    @pipelines = []
  end

  def execute
    # Make SIGINT/SIGTERM shutdown the pipeline.
    sigint_id = trap_sigint()
    sigterm_id = trap_sigterm()

    @pipelines.each(&:run) # blocking operation. works now because size <= 1
    return 0
  rescue => e
    report I18n.t("oops", :error => e)
    report e.backtrace if @logger.debug? || $DEBUGLIST.include?("stacktrace")
    return 1
  ensure
    Stud::untrap("INT", sigint_id) unless sigint_id.nil?
    Stud::untrap("TERM", sigterm_id) unless sigterm_id.nil?
  end # def execute

  def add_pipeline(config, filter_workers)
    pipeline = LogStash::Pipeline.new(config)
    pipeline.configure("filter-workers", filter_workers)
    @pipelines << pipeline
  end

  private
  # Emit a warning message.
  def warn(message)
    # For now, all warnings are fatal.
    raise LogStash::ConfigurationError, message
  end # def warn

  # Emit a failure message and abort.
  def fail(message)
    raise LogStash::ConfigurationError, message
  end # def fail

  def report(message)
    @logger.log(message)
  end

  def trap_sigint
    Stud::trap("INT") do

      if @interrupted_once
        @logger.fatal(I18n.t("logstash.agent.forced_sigint"))
        exit
      else
        @logger.warn(I18n.t("logstash.agent.sigint"))
        Thread.new(@logger) {|logger| sleep 5; logger.warn(I18n.t("logstash.agent.slow_shutdown")) }
        @interrupted_once = true
        @pipelines.each(&:shutdown)
      end
    end
  end

  def trap_sigterm
    Stud::trap("TERM") do
      @logger.warn(I18n.t("logstash.agent.sigterm"))
      @pipelines.each(&:shutdown)
    end

  end
end # class LogStash::Agent
