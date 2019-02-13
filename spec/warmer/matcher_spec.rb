# frozen_string_literal: true

describe Warmer::Matcher do
  subject(:matcher) { described_class.new }

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
      allow(Warmer.redis).to receive(:lpop).and_return('cool_instance')
      allow(matcher).to receive(:get_instance_object).and_return(true)
      allow(matcher).to receive(:label_instance).and_return(true)
    end

    it 'returns the instance' do
      expect(matcher.request_instance('fake_group')).to eq('cool_instance')
    end
  end

  context 'when no matching instance is found but there is a better one' do
    before do
      allow(Warmer.redis).to receive(:lpop).and_return(
        'cool_instance', 'better_instance'
      )
      allow(matcher).to receive(:get_instance_object).and_return(nil, true)
      allow(matcher).to receive(:label_instance).and_return(true)
    end

    it 'returns the better instance' do
      expect(matcher.request_instance('fake_group')).to eq('better_instance')
    end
  end

  context 'when instance object does not exist' do
    it 'returns nil' do
      expect(matcher.send(:get_instance_object, bad_instance)).to be_nil
    end
  end
end
