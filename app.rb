require 'yaml'
require 'erb'
require './workers/compilation_job'
require './workers/mixpanel_tracking_event'
require './helpers/authentication'

class Noteface < Sinatra::Base
  enable :sessions

  configure do
    @config ||= YAML.load_file('config/settings.yml')
    set :session_secret, @config['session_secret']
  end

  before do
    @config ||= YAML.load_file('config/settings.yml')
    @redis ||= Redis.new # assume localhost:6379
    Resque.redis = @redis
    session[:user_id] ||= SecureRandom.hex
  end

  helpers Sinatra::JSON
  helpers Helpers::Authentication

  helpers do
    def serve_pdf(document_name, sha)
      if sha
        unless authorized?
          user_info = {
            ip: request.ip,
            user_agent: request.user_agent,
            time: Time.now.to_i,
            sha: sha
          }

          mixpanel_properties = {
            ip_address: request.ip,
            user_agent: request.user_agent,
            document: document_name,
            sha: sha,
            referred_by: request.referer
          }

          Resque.enqueue(MixpanelTrackingEvent, session[:user_id], user_info, 'Downloaded File', mixpanel_properties)
        end

        file_path = "./documents/#{document_name}/#{sha}/#{document_name}.pdf"

        if File.exists?(file_path)
          headers \
            'Content-Type' => 'application/pdf',
            'Etag'         => sha
          return File.read(file_path)
        end
      end

      404
    end
  end

  post '/receive_push/:secret' do
    halt 403 if params[:secret] != @config["github"]["post_receive_secret"]
    payload = JSON.parse params[:payload]
    halt 304 if payload["ref"] != "refs/heads/master" # only build on master

    files_to_compile = []
    payload["commits"].each do |commit|
      files_to_compile << [commit["added"], commit["modified"]]
    end

    files_to_compile.flatten!
    files_to_compile.uniq!
    files_to_compile.select! { |f| f[-4..-1] == ".tex" }

    files_to_compile.each do |file|
      puts "Queuing #{file}@#{payload["after"]} for compilation."
      Resque.enqueue(CompilationJob, file, payload["head_commit"], payload["repository"])
    end

    202
  end

  get '/dl/latest/:document_name.pdf' do
    document_name = params[:document_name]
    latest_sha = @redis.get("#{document_name}:latest")

    serve_pdf params[:document_name], latest_sha
  end

  get '/dl/:sha/:document_name.pdf' do
    serve_pdf params[:document_name], params[:sha]
  end

  get '/documents.json' do
    document_names = @redis.smembers('documents')
    documents = {}

    if document_names
      document_names.each do |document_name| 
        latest_sha = @redis.get("#{document_name}:latest")
        last_modified = @redis.get("#{latest_sha}:timestamp")
        course_code = @redis.get("#{document_name}:course:code")
        course_name = @redis.get("#{document_name}:course:name")

        # Not currently extracted from LaTeX files automatically:
        course_term = @redis.get("#{document_name}:course:term")

        documents[document_name] = {
          course: {
            code: course_code,
            name: course_name,
            term: course_term
          },
          sha: latest_sha,
          timestamp: last_modified
        }
      end
    end

    headers "Access-Control-Allow-Origin" => "*"
    json documents
  end

  get '/dash/stats.json' do
    protected!

    json all_stats
  end

  # TODO - dashboard for viewing documents and stats
  get '/dash' do
    protected!

    erb :dash
  end

  not_found do
    redirect @config['redirects']['error']
  end

  error do
    redirect @config['redirects']['error']
  end
end
