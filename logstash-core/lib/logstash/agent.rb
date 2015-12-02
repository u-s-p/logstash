# encoding: utf-8
require "logstash/environment"
require "logstash/errors"
require "logstash/config/cpu_core_strategy"
require "logstash/instrument/collector"
require "logstash/instrument/metric"
require "logstash/pipeline"
require "uri"
require "stud/trap"

LogStash::Environment.load_locale!

class LogStash::Agent

  attr_writer :logger

  def initialize
    @pipelines = {}
  end

  def execute
    # Make SIGINT/SIGTERM shutdown the pipeline.
    sigint_id = trap_sigint()
    sigterm_id = trap_sigterm()

    @pipelines.each {|_, p| p.run } # blocking operation. works now because size <= 1
    return 0
  rescue => e
    @logger.fatal I18n.t("oops", :error => e)
    @logger.fatal e.backtrace if @logger.debug? || $DEBUGLIST.include?("stacktrace")
    return 1
  ensure
    Stud::untrap("INT", sigint_id) unless sigint_id.nil?
    Stud::untrap("TERM", sigterm_id) unless sigterm_id.nil?
  end # def execute

  def add_pipeline(pipeline_id, config_str, settings = {})
    @pipelines[pipeline_id] = LogStash::Pipeline.new(config_str, settings.merge(:pipeline_id => pipeline_id))
    add_metric_pipeline if settings.fetch(:metric, false)
  end

  private
  def add_metric_pipeline
    metric_pipeline_config =<<-EOS
    input {
      metrics {}
    }
    
    output {
      elasticsearch {
        host => "127.0.0.1"
        index => "metrics-%dd-%mm-%YY"
      }
    }
    EOS

    add_pipeline(:metric, metric_pipeline_config, { :metric => false }) unless pipeline_exist?(:metric)
  end

  def pipeline_exist?(pipeline_id)
    !@pipelines[pipeline_id].nil?
  end

  # Emit a warning message.
  def warn(message)
    # For now, all warnings are fatal.
    raise LogStash::ConfigurationError, message
  end # def warn

  # Emit a failure message and abort.
  def fail(message)
    raise LogStash::ConfigurationError, message
  end # def fail

  def shutdown_pipelines
    @pipelines.each do |_, pipeline|
      pipeline.shutdown do
        ::LogStash::ShutdownController.start(pipeline)
      end
    end
  end

  def trap_sigterm
    Stud::trap("TERM") do
      @logger.warn(I18n.t("logstash.agent.sigterm"))
      shutdown_pipelines
    end
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
        shutdown_pipelines
      end
    end
  end
end # class LogStash::Agent
