require "spec_helper"
require 'rspec'

describe Wrest::CacheLogic do
  before :each do
    @cache       = Hash.new
    @request_uri = 'http://localhost/foo'.to_uri
    @get         = Wrest::Native::Get.new(@request_uri, {}, {}, {:cache_store => @cache})
    @ok_response = Wrest::Native::Response.new(build_ok_response('', cacheable_headers()))
    @get.stub!(:invoke_without_cache_check).and_return(@ok_response)
    @cache_logic = @get.cache_logic
  end

  context "Factory" do
    it "should create a Null class if cache store is nil" do
      Wrest::CacheLogic::NullCacheLogic.should_receive(:new)
      Wrest::CacheLogic::new(@get, nil)
    end
    it "should create a Default cache logic class if cache store is available" do
      Wrest::CacheLogic::DefaultCacheLogic.should_receive(:new)
      Wrest::CacheLogic::new(@get, {})
    end
  end

  context "null caching" do
    it "should always call invoke without cache check" do
      @get = Wrest::Native::Get.new(@request_uri, {}, {}, {})
      @get.should_receive(:invoke_without_cache_check)

      cache_logic = Wrest::CacheLogic::NullCacheLogic.new(@get)
      cache_logic.get
    end
  end

  context "default caching" do
    it "should check if response already exists in cache when making a request" do
      @cache.should_receive(:[]).with(@get.hash)
      @cache_logic.get
    end

    it "should give a new response if it is not in the cache" do
      @cache.should_receive(:[]).with(@get.hash).and_return(nil)
      @cache_logic.get.should == @ok_response
    end

    it "should cache the response after invoke makes a fresh request" do
      @cache.should_receive(:[]).with(@get.hash).and_return(nil)
      @get.should_receive(:invoke_without_cache_check).and_return(@ok_response)
      @cache_logic.should_receive(:cache).with(@ok_response)
      @get.invoke
    end

    it "should not call invoke_without_cache_check if response exists in cache" do
      @cache_logic.should_receive(:get).and_return(@ok_response)
      @get.should_not_receive(:invoke_without_cache_check)
      @get.invoke
    end

    it "should check whether the cache entry has expired" do
      @cache.should_receive(:[]).and_return(@ok_response)
      @ok_response.should_receive(:expired?)
      @cache_logic.get
    end

    it "should use the cached response if it finds a matching one that hasn't expired" do
      @cached_response=Wrest::Native::Response.new(build_ok_response('', cacheable_headers().tap { |h| h["random"] = 123 }))

      @cache.should_receive(:[]).with(@get.hash).and_return(@cached_response)
      @cached_response.should_receive(:expired?).and_return(false)

      @cache_logic.get.should == @cached_response
    end

    it "should check whether an expired cache entry can be validated" do
      @cache.should_receive(:[]).with(@get.hash).and_return(@ok_response)

      @ok_response.should_receive(:expired?).and_return(true)
      @ok_response.should_receive(:can_be_validated?)

      @cache_logic.get
    end

    context "Cache Validation" do

      context "how to validate a cache entry" do
        before :all do
          @default_options = {:follow_redirects=>true, :follow_redirects_count=>0, :follow_redirects_limit=>5}
        end

        it "should send an If-Not-Modified Get request if the cache has a Last-Modified" do
          @ok_response.should_receive(:expired?).and_return(true)
          @ok_response.can_be_validated?.should == true

          @cache.should_receive(:[]).with(@get.hash).and_return(@ok_response)

          direct_get = Wrest::Native::Get.new(@request_uri)
          direct_get.should_receive(:invoke).and_return(@ok_response)

          Wrest::Native::Get.should_receive(:new).with(@request_uri, {}, {"if-modified-since" => @ok_response.headers["last-modified"]}, @default_options).and_return(direct_get)

          @cache_logic.get
        end
        it "should send an If-None-Match Get request if the cache has an ETag" do

          response_with_etag = Wrest::Native::Response.new(build_ok_response('', cacheable_headers().tap { |h|
            h.delete "last-modified"
            h["etag"]='123'
          }))

          response_with_etag.should_receive(:expired?).and_return(true)
          response_with_etag.can_be_validated?.should == true

          @cache.should_receive(:[]).with(@get.hash).and_return(response_with_etag)

          direct_get = Wrest::Native::Get.new(@request_uri)
          direct_get.should_receive(:invoke).and_return(response_with_etag)

          Wrest::Native::Get.should_receive(:new).with(@request_uri, {}, {"if-none-match" => "123"}, @default_options).and_return(direct_get)

          @cache_logic.get
        end
      end

      context "using a validation response" do
        before :each do
          one_day_back    = (Time.now - 60*60*24).httpdate

          @cached_response=Wrest::Native::Response.new(build_ok_response('', cacheable_headers().tap { |h| h["random"] = 235; h["expires"] = one_day_back }))

          @cache.should_receive(:[]).with(@get.hash).and_return(@cached_response)
        end

        # 304 is Not Modified
        it "should use the cached response if the server returns 304" do
          not_modified_response = @ok_response.clone
          not_modified_response.should_receive(:code).any_number_of_times.and_return('304')

          @cache_logic.should_receive(:send_validation_request_for).and_return(not_modified_response)

          # only check the body, can't compare the entire object - the headers from 304 would be merged with the cached response's headers.
          @cache_logic.get.body.should == @cached_response.body
        end

        it "should update the headers of the cached response with the headers from the 304" do
          not_modified_response = @ok_response.clone
          not_modified_response.should_receive(:code).any_number_of_times.and_return('304')

          @cache_logic.should_receive(:send_validation_request_for).and_return(not_modified_response)
          @cache_logic.should_receive(:update_cache_headers_for).with(@cached_response, not_modified_response)

          @cache_logic.get

        end
        it "should use it if the server returns a new response" do
          new_response = Wrest::Native::Response.new(build_ok_response('', cacheable_headers()))
          new_response.should_receive(:code).any_number_of_times.and_return('200')

          @cache_logic.should_receive(:send_validation_request_for).and_return(new_response)

          @cache_logic.get.should == new_response
        end

        it "should also cache it when the server returns a new response" do
          new_response = Wrest::Native::Response.new(build_ok_response('', cacheable_headers()))
          new_response.should_receive(:code).any_number_of_times.and_return('200')

          @cache_logic.should_receive(:send_validation_request_for).and_return(new_response)
          @cache.should_receive(:[]=).once

          @cache_logic.get.should == new_response
        end
      end
    end
  end

  context "conditions governing caching" do
    it "should try to cache a response if was not already cached" do
      @get.should_receive(:invoke_without_cache_check).and_return(@ok_response)
      @cache_logic.should_receive(:cache).with(@ok_response)
      @cache_logic.get
    end

    it "should check whether a response is cacheable when trying to cache a response" do
      @cache.should_receive(:[]).with(@get.hash).and_return(nil)
      @get.should_receive(:invoke_without_cache_check).and_return(@ok_response)
      @ok_response.should_receive(:cacheable?).and_return(false)
      @cache_logic.get
    end

    it "should store response in cache if response is cacheable" do
      response = @ok_response
      response.cacheable?.should == true
      @get.should_receive(:invoke_without_cache_check).and_return(response)
      @cache.should_receive(:[]=).with(@get.hash, response)
      @cache_logic.get
    end
  end
end