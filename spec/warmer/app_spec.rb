# frozen_string_literal: true

require_relative '../fake_compute_service'

describe Warmer::App do
  include Rack::Test::Methods

  let(:app) { described_class }

  let :fake_compute do
    FakeComputeService.new
  end

  let :request_body do
    {
      'image_name': 'https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/super-great-fake-image',
      'machine_type': 'n1-standard-1',
      'public_ip': 'true'
    }
  end

  let :instance do
    JSON.generate(
      name: 'super-great-test-instance',
      zone: 'us-central1-c'
    )
  end

  let :bad_instance do
    JSON.generate(
      name: 'im-not-real',
      zone: 'us-central1-c'
    )
  end

  before :each do
    allow(Warmer).to receive(:compute).and_return(fake_compute)
  end

  describe 'GET /' do
    it 'can talk' do
      get '/'
      expect(last_response.body).to match(/^warmer no warming$/)
    end
  end

  describe 'POST /request-instance' do
    context 'when a nonexistent image is requested' do
      it 'responds 404' do
        post '/request-instance', request_body.to_json,
             'CONTENT_TYPE' => 'application/json'
        # We know we won't get a VM for a fake image, but we want to make sure all the parsing happens
        expect(last_response.status).to eq(404)
      end
    end
  end

  describe 'GET /pool-configs' do
    it 'is ok' do
      get '/pool-configs'
      expect(last_response).to be_ok
    end

    context 'when a nonexistent pool is requested' do
      it 'responds 404' do
        get '/pool-configs/fake-test-pool'
        expect(last_response.status).to eq(404)
      end
    end
  end

  describe 'POST /pool-configs/{pool-name}/{?count}' do
    it 'creates the named pool' do
      post '/pool-configs/super:testpool/1'
      expect(last_response).to be_ok

      get '/pool-configs/super:testpool'
      expect(last_response).to be_ok
    end
  end

  describe 'DELETE /pool-configs/{pool-name}' do
    it 'deletes the named pool' do
      post '/pool-configs/super:testpool/1'
      expect(last_response).to be_ok

      get '/pool-configs/super:testpool'
      expect(last_response).to be_ok

      delete '/pool-configs/super:testpool'
      expect(last_response.status).to eq(204)

      get '/pool-configs/super:testpool'
      expect(last_response.status).to eq(404)
    end
  end
end
