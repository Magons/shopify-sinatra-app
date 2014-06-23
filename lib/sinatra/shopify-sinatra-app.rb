require 'sinatra/base'
require 'sinatra/redis'
require 'sinatra/activerecord'
require 'sinatra/twitter-bootstrap'

require 'resque'
require 'rack-flash'
require 'attr_encrypted'
require 'active_support/all'

require 'shopify_api'
require 'omniauth-shopify-oauth2'

module Sinatra
  module Shopify

    module Methods
      def install
        raise NotImplementedError
      end

      def uninstall
        raise NotImplementedError
      end

      def logout
        session[:shopify] = nil
      end

      def base_url
        @base_url ||= "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}"
      end

      def current_shop
        session[:shopify][:shop] if session.has_key?(:shopify)
      end

      def current_shop_url
        "https://#{current_shop}" if current_shop
      end

      def shopify_session(&blk)
        if !session.has_key?(:shopify)
          get_session
        elsif params[:shop].present? && session[:shopify][:shop] != sanitize_shop_param(params)
          logout
          get_session
        else
          shop_name = session[:shopify][:shop]
          token = session[:shopify][:token]

          api_session = ShopifyAPI::Session.new(shop_name, token)
          ShopifyAPI::Base.activate_session(api_session)

          yield shop_name
        end
      end

      def webhook_session(&blk)
        return unless verify_shopify_webhook

        shop_name = request.env['HTTP_X_SHOPIFY_SHOP_DOMAIN']
        shop = Shop.find_by(:name => shop_name)

        if shop.present?
          params = ActiveSupport::JSON.decode(request.body.read.to_s)
          api_session = ShopifyAPI::Session.new(shop_name, shop.token)
          ShopifyAPI::Base.activate_session(api_session)

          yield shop, params

          status 200
        end
      end

      def webhook_job(jobKlass)
        return unless verify_shopify_webhook

        params = ActiveSupport::JSON.decode(request.body.read.to_s)
        shop_name = request.env['HTTP_X_SHOPIFY_SHOP_DOMAIN']

        Resque.enqueue(jobKlass, params, shop_name)

        status 200
      end

      private

      def get_session
        shop_name = sanitize_shop_param(params)
        shop = Shop.find_by(:name => shop_name)

        return_to = request.env["sinatra.route"].split(' ').last

        if shop.present?
          session[:shopify] ||= {}
          session[:shopify][:shop] = shop.name
          session[:shopify][:token] = shop.token
          redirect return_to
        else
          authenticate(return_to)
        end
      end

      def authenticate(return_to = '/')
        if shop_name = sanitize_shop_param(params)
          redirect_url = "/auth/shopify?shop=#{shop_name}&return_to=#{base_url}#{return_to}"
          fullpage_redirect_to redirect_url
        else
          redirect "/install"
        end
      end

      def fullpage_redirect_to(redirect_url)
        @fullpage_redirect_to = redirect_url

        erb "<script type='text/javascript'>
              window.top.location.href = '<%= @fullpage_redirect_to %>';
            </script>", :layout => false
      end

      def sanitize_shop_param(params)
        return unless params[:shop].present?
        name = params[:shop].to_s.strip
        name += '.myshopify.com' if !name.include?("myshopify.com") && !name.include?(".")
        name.gsub!('https://', '')
        name.gsub!('http://', '')

        u = URI("http://#{name}")
        u.host.ends_with?(".myshopify.com") ? u.host : nil
      end

      def verify_shopify_webhook
        data = request.body.read.to_s
        digest = OpenSSL::Digest::Digest.new('sha256')
        calculated_hmac = Base64.encode64(OpenSSL::HMAC.digest(digest, app.settings.shared_secret, data)).strip
        request.body.rewind

        calculated_hmac == request.env['HTTP_X_SHOPIFY_HMAC_SHA256']
      end
    end

    def self.registered(app)
      app.helpers Shopify::Methods
      app.register Sinatra::ActiveRecordExtension
      app.register Sinatra::Twitter::Bootstrap::Assets

      app.set :database_file, File.expand_path("config/database.yml")
      app.set :views, File.expand_path("views")
      app.set :public_folder, File.expand_path("public")
      app.set :erb, :layout => :'layouts/application'
      app.set :protection, :except => :frame_options

      app.enable :sessions
      app.enable :inline_templates

      app.set :scope, YAML.load(File.read(File.expand_path("config/app.yml")))["scope"]

      app.set :api_key, ENV['SHOPIFY_API_KEY']
      app.set :shared_secret, ENV['SHOPIFY_SHARED_SECRET']
      app.set :secret, ENV['SECRET']

      app.use Rack::Flash, :sweep => true
      app.use Rack::MethodOverride
      app.use Rack::Session::Cookie, :key => '#{base_url}.session',
                                     :path => '/',
                                     :secret => app.settings.secret,
                                     :expire_after => 2592000

      app.set :redis_url, ENV["REDISCLOUD_URL"] || "redis://localhost:6379/"
      redis_uri = URI.parse(app.settings.redis_url)
      Resque.redis = ::Redis.new(:host => redis_uri.host,
                               :port => redis_uri.port,
                               :password => redis_uri.password)
      Resque.redis.namespace = "resque"
      app.set :redis, app.settings.redis_url

      app.use OmniAuth::Builder do
        provider :shopify,
          app.settings.api_key,
          app.settings.shared_secret,

          :scope => app.settings.scope,

          :setup => lambda { |env|
            params = Rack::Utils.parse_query(env['QUERY_STRING'])
            site_url = "https://#{params['shop']}"
            env['omniauth.strategy'].options[:client_options][:site] = site_url
          }
      end

      ShopifyAPI::Session.setup({:api_key => app.settings.api_key,
                                 :secret => app.settings.shared_secret})

      app.get '/install' do
        erb :install, :layout => false
      end

      # endpoint for the app/uninstall webhook
      app.post '/uninstall.json' do
        uninstall
      end

      app.post '/login' do
        authenticate
      end

      app.get '/logout' do
        logout
        redirect '/install'
      end

      app.get '/auth/shopify/callback' do
        shop_name = params["shop"]
        token = request.env['omniauth.auth']['credentials']['token']

        session[:shopify] ||= {}
        session[:shopify][:shop] = shop_name
        session[:shopify][:token] = token

        if Shop.where(:name => shop_name).blank?
          Shop.create(:name => shop_name, :token => token)
          install
        end

        return_to = env['omniauth.params']['return_to']
        redirect return_to
      end

      app.get '/auth/failure' do
        erb "<h1>Authentication Failed:</h1>
             <h3>message:<h3> <pre>#{params}</pre>", :layout => false
      end
    end
  end

  class Shop < ActiveRecord::Base

    def self.secret
      @secret ||= ENV['SECRET']
    end

    attr_encrypted :token, :key => secret, :attribute => 'token_encrypted'
    validates_presence_of :name, :token
  end

  register Shopify
end
