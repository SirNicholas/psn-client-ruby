# frozen_string_literal: true

RSpec.describe PSN::Auth do
  let(:authorize_url) { "https://ca.account.sony.com/api/authz/v3/oauth/authorize" }
  let(:token_url) { "https://ca.account.sony.com/api/authz/v3/oauth/token" }

  def stub_authorize(npsso: "NPSSO123", code: "v3.ABC")
    stub_request(:get, authorize_url)
      .with(query: hash_including("client_id" => "09515159-7237-4370-9b40-3806e67c0891"),
            headers: { "Cookie" => "npsso=#{npsso}" })
      .to_return(status: 302,
                 headers: { "Location" => "com.scee.psxandroid.scecompcall://redirect?code=#{code}&cid=x" })
  end

  def token_body(access: "AT-1", refresh: "RT-1", expires_in: 3600)
    { access_token: access, refresh_token: refresh, expires_in: expires_in }.to_json
  end

  it "requires exactly one of npsso or refresh_token" do
    expect { described_class.new }.to raise_error(ArgumentError)
    expect { described_class.new(npsso: "a", refresh_token: "b") }.to raise_error(ArgumentError)
  end

  it "exchanges an NPSSO for tokens on first access" do
    stub_authorize
    token_stub = stub_request(:post, token_url)
                 .with(body: hash_including("grant_type" => "authorization_code", "code" => "v3.ABC"))
                 .to_return(status: 200, body: token_body, headers: { "Content-Type" => "application/json" })

    auth = described_class.new(npsso: "NPSSO123")
    expect(auth.access_token).to eq("AT-1")
    expect(auth.refresh_token).to eq("RT-1")
    expect(token_stub).to have_been_requested.once
  end

  it "reuses a cached unexpired token" do
    stub_authorize
    stub_request(:post, token_url)
      .to_return(status: 200, body: token_body, headers: { "Content-Type" => "application/json" })
    auth = described_class.new(npsso: "NPSSO123")
    2.times { auth.access_token }
    expect(WebMock).to have_requested(:post, token_url).once
  end

  it "raises AuthenticationError when the NPSSO is rejected" do
    stub_request(:get, authorize_url)
      .with(query: hash_including("client_id"))
      .to_return(status: 200, body: "<html>sign in</html>")

    auth = described_class.new(npsso: "expired")
    expect { auth.access_token }.to raise_error(PSN::AuthenticationError, /NPSSO/)
  end

  it "starts from a refresh token without touching the authorize endpoint" do
    stub_request(:post, token_url)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "RT-0"))
      .to_return(status: 200, body: token_body(access: "AT-9", refresh: "RT-9"),
                 headers: { "Content-Type" => "application/json" })

    auth = described_class.new(refresh_token: "RT-0")
    expect(auth.access_token).to eq("AT-9")
    expect(auth.refresh_token).to eq("RT-9")
    expect(WebMock).not_to have_requested(:get, authorize_url)
  end

  it "auto-refreshes an expired access token" do
    stub_request(:post, token_url).to_return(
      { status: 200, body: token_body(access: "AT-old", refresh: "RT-1", expires_in: 0),
        headers: { "Content-Type" => "application/json" } },
      { status: 200, body: token_body(access: "AT-new", refresh: "RT-2"),
        headers: { "Content-Type" => "application/json" } }
    )

    auth = described_class.new(refresh_token: "RT-0")
    expect(auth.access_token).to eq("AT-old")
    expect(auth.access_token).to eq("AT-new")
    expect(auth.refresh_token).to eq("RT-2")
  end

  it "raises AuthenticationError when the token endpoint fails" do
    stub_request(:post, token_url).to_return(status: 400, body: '{"error":"invalid_grant"}')
    auth = described_class.new(refresh_token: "bad")
    expect { auth.access_token }.to raise_error(PSN::AuthenticationError) { |e| expect(e.response[:status]).to eq(400) }
  end

  describe "on_token_refresh" do
    let(:json_headers) { { "Content-Type" => "application/json" } }

    it "reports the refresh token gained from the initial NPSSO exchange" do
      stub_authorize
      stub_request(:post, token_url).to_return(status: 200, body: token_body, headers: json_headers)

      events = []
      auth = described_class.new(npsso: "NPSSO123", on_token_refresh: ->(token, _expires_at) { events << token })
      auth.access_token
      expect(events).to eq(["RT-1"])
    end

    it "reports each rotation exactly once" do
      stub_request(:post, token_url).to_return(
        { status: 200, body: token_body(access: "AT-1", refresh: "RT-1", expires_in: 0), headers: json_headers },
        { status: 200, body: token_body(access: "AT-2", refresh: "RT-2"), headers: json_headers }
      )

      events = []
      auth = described_class.new(refresh_token: "RT-0", on_token_refresh: ->(token, _expires_at) { events << token })
      2.times { auth.access_token }
      expect(events).to eq(%w[RT-1 RT-2])
    end

    it "passes the expiry of the newly issued tokens, not the previous one" do
      now = Time.at(1_700_000_000)
      allow(Time).to receive(:now).and_return(now)
      stub_request(:post, token_url).to_return(
        { status: 200, body: token_body(access: "AT-1", refresh: "RT-1", expires_in: 0), headers: json_headers },
        { status: 200, body: token_body(access: "AT-2", refresh: "RT-2", expires_in: 3600), headers: json_headers }
      )

      events = []
      auth = described_class.new(refresh_token: "RT-0",
                                 on_token_refresh: ->(token, expires_at) { events << [token, expires_at] })
      2.times { auth.access_token }
      expect(events).to eq([["RT-1", now - 60], ["RT-2", now + 3540]])
      expect(events.last.last).to eq(auth.expires_at)
    end

    it "keeps calling one-argument lambdas with just the token" do
      stub_request(:post, token_url).to_return(status: 200, body: token_body, headers: json_headers)

      events = []
      auth = described_class.new(refresh_token: "RT-0", on_token_refresh: ->(token) { events << token })
      auth.access_token
      expect(events).to eq(["RT-1"])
    end

    it "keeps calling one-argument Method objects with just the token" do
      stub_request(:post, token_url).to_return(status: 200, body: token_body, headers: json_headers)

      store = Class.new do
        attr_reader :saved

        def save(token) = (@saved = token)
      end.new
      auth = described_class.new(refresh_token: "RT-0", on_token_refresh: store.method(:save))
      auth.access_token
      expect(store.saved).to eq("RT-1")
    end

    it "stays quiet when the server echoes the same refresh token" do
      stub_request(:post, token_url)
        .to_return(status: 200, body: token_body(refresh: "RT-0"), headers: json_headers)

      events = []
      auth = described_class.new(refresh_token: "RT-0", on_token_refresh: ->(token, _expires_at) { events << token })
      auth.access_token
      expect(events).to be_empty
    end

    it "propagates callback exceptions" do
      stub_request(:post, token_url).to_return(status: 200, body: token_body, headers: json_headers)

      auth = described_class.new(refresh_token: "RT-0", on_token_refresh: ->(_t, _expires_at) { raise "disk full" })
      expect { auth.access_token }.to raise_error(RuntimeError, "disk full")
    end

    it "runs the callback outside the auth lock so it can re-enter" do
      stub_request(:post, token_url)
        .to_return(status: 200, body: token_body(access: "AT-9", refresh: "RT-9"), headers: json_headers)

      reentrant = nil
      auth = described_class.new(refresh_token: "RT-0",
                                 on_token_refresh: ->(_t, _expires_at) { reentrant = auth.access_token })
      expect(auth.access_token).to eq("AT-9")
      expect(reentrant).to eq("AT-9")
      expect(WebMock).to have_requested(:post, token_url).once
    end
  end
end
