require 'aws-sdk-s3'
require 'log4r'
require 'net/http'
require 'uri'
require 'pry-byebug'

module VagrantPlugins
  module S3Auth
    module Util
      S3_HOST_MATCHER = /^((?<bucket>[[:alnum:]\-\.]+).)?s3([[:alnum:]\-\.]+)?\.(amazonaws|backblazeb2)\.com$/

      # The list of environment variables that the AWS Ruby SDK searches
      # for access keys. Sadly, there's no better way to determine which
      # environment variable the Ruby SDK is using without mirroring the
      # logic ourself.
      #
      # See: https://github.com/aws/aws-sdk-ruby/blob/ab0eb18d0ce0a515254e207dae772864c34b048d/aws-sdk-core/lib/aws-sdk-core/credential_provider_chain.rb#L42
      AWS_ACCESS_KEY_ENV_VARS = %w[AWS_ACCESS_KEY_ID AMAZON_ACCESS_KEY_ID AWS_ACCESS_KEY].freeze

      DEFAULT_REGION = 'us-east-1'.freeze
      DEFAULT_ENDPOINT = 'https://s3.us-east-1.amazon.com'.freeze
      LOCATION_TO_REGION = Hash.new { |_, key| key }.merge(
        '' => DEFAULT_REGION,
        'EU' => 'eu-west-1'
      )

      class NullObject
        def method_missing(*) # rubocop:disable Style/MethodMissing
          nil
        end
      end

      def self.s3_client(region = DEFAULT_REGION, endpoint = DEFAULT_ENDPOINT)
        pp "s3_client: " + region + "--" + endpoint
        ::Aws::S3::Client.new(region: region, endpoint: endpoint)
      end

      def self.s3_resource(region = DEFAULT_REGION, endpoint = DEFAULT_ENDPOINT)
        pp "s3_resource: " + region + "--" + endpoint
        ::Aws::S3::Resource.new(client: s3_client(region, endpoint))
      end

      def self.s3_object_for(url, follow_redirect = true)
        url = URI(url)
        pp url
        if url.scheme == 's3'
          bucket = url.host
          key = url.path[1..-1]
          raise Errors::MalformedShorthandURLError, url: url unless bucket && key
        elsif match = S3_HOST_MATCHER.match(url.host)
          components = url.path.split('/').delete_if(&:empty?)
          bucket = url.host.split('.').first

          key = url.path.gsub(/^\//, "")
          endpoint = "https://" + url.host.sub(/\.?#{bucket}\.?/, "")
          # bucket = match['bucket'] || components.shift
          # key = components.join('/')
        end

        if bucket && key
          pp endpoint
          get_bucket_region(bucket, endpoint)
          s3_resource(get_bucket_region(bucket, endpoint), endpoint).bucket(bucket).object(key)
        elsif follow_redirect
          response = Net::HTTP.get_response(url) rescue nil
          if response.is_a?(Net::HTTPRedirection)
            s3_object_for(response['location'], false)
          end
        end
      end


      def self.s3_url_for(method, s3_object)
        s3_object.presigned_url(method, expires_in: 60 * 10)
      end

      def self.get_bucket_region(bucket, endpoint)
        if endpoint.include? "backblaze"
          region = URI(endpoint).host.split('.')[1]
        else
          region = LOCATION_TO_REGION[
            s3_client.get_bucket_location(bucket: bucket).location_constraint
          ]
        end
        return region
      rescue ::Aws::S3::Errors::AccessDenied
        raise Errors::BucketLocationAccessDeniedError, bucket: bucket
      end

      def self.s3_credential_provider
        # Providing a NullObject here is the same as instantiating a
        # client without specifying a credentials config, like we do in
        # `self.s3_client`.
        ::Aws::CredentialProviderChain.new(NullObject.new).resolve
      end
    end
  end
end
