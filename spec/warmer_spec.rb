# frozen_string_literal: true

describe Warmer do
  after :each do
    Warmer.redis.hdel('poolconfigs', 'foobar')
  end

  it 'has pools' do
    old_size = Warmer.pools.size
    Warmer.redis.hset('poolconfigs', 'foobar', 1)
    expect(Warmer.pools.size).to eq(old_size + 1)
  end
end
