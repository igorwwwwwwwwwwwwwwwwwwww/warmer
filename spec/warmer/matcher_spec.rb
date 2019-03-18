# frozen_string_literal: true

require_relative '../fake_compute_service'

describe Warmer::Matcher do
  subject(:matcher) { described_class.new(adapter) }
  let(:adapter) { Warmer::Adapter::Google.new(Warmer.config, compute: fake_compute) }
  let(:fake_compute) { FakeComputeService.new }

  let :request_body do
    {
      'image_name' => 'https://www.googleapis.com/compute/v1/projects/eco-emissary-99515/global/images/super-great-fake-image',
      'machine_type' => 'n1-standard-1',
      'public_ip' => 'true'
    }
  end

  let :bad_instance do
    JSON.generate(
      name: 'im-not-real',
      zone: 'us-central1-c'
    )
  end

  context 'when there is no matching pool name' do
    it 'returns nil' do
      expect(matcher.match(request_body)).to be_nil
    end
  end

  context 'when there is no matching instance' do
    it 'returns nil' do
      instance = matcher.request_instance('fake_group')
      expect(instance).to be_nil
    end
  end

  context 'when a matching instance is found' do
    before do
      allow(Warmer.redis).to receive(:lpop).and_return('{"name":"cool_instance"}')
      allow(adapter).to receive(:get_instance).and_return(true)
      allow(adapter).to receive(:label_instance).and_return(true)
    end

    it 'returns the instance' do
      expect(matcher.request_instance('fake_group')).to eq('{"name":"cool_instance"}')
    end
  end

  context 'when no matching instance is found but there is a better one' do
    before do
      allow(Warmer.redis).to receive(:lpop).and_return(
        '{"name":"cool_instance"}', '{"name":"better_instance"}'
      )
      allow(adapter).to receive(:get_instance).and_return(nil, true)
      allow(adapter).to receive(:label_instance).and_return(true)
    end

    it 'returns the better instance' do
      expect(matcher.request_instance('fake_group')).to eq('{"name":"better_instance"}')
    end
  end
end
