# frozen_string_literal: true

RSpec.describe PSN::Resources::Games do
  subject(:games) { described_class.new(connection, users) }

  let(:connection) { instance_double(PSN::Connection) }
  let(:users) { instance_double(PSN::Resources::Users) }

  it "fetches all pages of played titles for the authenticated user" do
    allow(users).to receive(:account_id).with(nil).and_return("me")
    allow(connection).to receive(:get)
      .with(:mobile, "/api/gamelist/v2/users/me/titles", { "limit" => 200, "offset" => 0 })
      .and_return({ "titles" => fixture("games_list"), "totalItemCount" => 2 })

    result = games.played.to_a
    expect(result.size).to eq(2)
    expect(result.first).to be_a(PSN::GameTitle)
    expect(result.first.name).to eq("ASTRO's PLAYROOM")
    expect(result.last.name).to eq("God of War")
  end

  it "fetches the pages of played titles until last_checked_date_time" do
    allow(users).to receive(:account_id).with(nil).and_return("me")
    allow(connection).to receive(:get)
      .with(:mobile, "/api/gamelist/v2/users/me/titles", { "limit" => 10, "offset" => 0 })
      .and_return({ "titles" => fixture("games_list"), "totalItemCount" => 1 })

    result = games.played(last_checked_date_time: Date.parse("2026-09-07").to_time, page_size: 10).to_a
    expect(result.size).to eq(1)
    expect(result.first).to be_a(PSN::GameTitle)
    expect(result.first.name).to eq("God of War")
  end

  it "resolves another user's online ID and pages lazily" do
    allow(users).to receive(:account_id).with("friend").and_return("42")
    allow(connection).to receive(:get)
      .with(:mobile, "/api/gamelist/v2/users/42/titles", { "limit" => 200, "offset" => 0 })
      .and_return({ "titles" => Array.new(200) { fixture("game_title") }, "totalItemCount" => 400 })

    expect(games.played(online_id: "friend")).to be_a(PSN::Collection)
    expect(games.played(online_id: "friend").first(3).size).to eq(3)
    expect(connection).to have_received(:get).once # second page never requested
  end

  describe "#library" do
    it "fetches the game library via the getUserGameList persisted query" do
      response = { "data" => { "gameLibraryTitlesRetrieve" => { "games" => [fixture("library_title")] } } }
      allow(connection).to receive(:graphql)
        .with("getUserGameList",
              { "categories" => "ps4_game,ps5_native_game", "limit" => 100 },
              PSN::Resources::Games::LIBRARY_HASH)
        .and_return(response)

      result = games.library.to_a
      expect(result.size).to eq(1)
      expect(result.first).to be_a(PSN::LibraryTitle)
      expect(result.first.name).to eq("ASTRO's PLAYROOM")
    end

    it "passes a custom limit and returns a lazy enumerator" do
      allow(connection).to receive(:graphql)
        .with("getUserGameList", hash_including("limit" => 5), PSN::Resources::Games::LIBRARY_HASH)
        .and_return({ "data" => { "gameLibraryTitlesRetrieve" => { "games" => [] } } })

      expect(games.library(limit: 5)).to be_a(Enumerator::Lazy)
      expect(games.library(limit: 5).to_a).to eq([])
    end
  end

  describe "#purchased" do
    def purchased_response(games_page)
      { "data" => { "purchasedTitlesRetrieve" => { "games" => games_page } } }
    end

    it "pages via start/size until an empty page (no total in the response)" do
      allow(connection).to receive(:graphql)
        .with("getPurchasedGameList", hash_including("size" => 200, "start" => 0),
              PSN::Resources::Games::PURCHASED_HASH)
        .and_return(purchased_response(Array.new(200) { fixture("purchased_game") }))
      allow(connection).to receive(:graphql)
        .with("getPurchasedGameList", hash_including("start" => 200),
              PSN::Resources::Games::PURCHASED_HASH)
        .and_return(purchased_response([]))

      result = games.purchased.to_a
      expect(result.size).to eq(200)
      expect(result.first).to be_a(PSN::PurchasedGame)
      expect(connection).to have_received(:graphql).twice
    end

    it "is lazy: .first(n) stops after the first page" do
      allow(connection).to receive(:graphql)
        .with("getPurchasedGameList",
              { "isActive" => true, "platform" => %w[ps4 ps5], "sortBy" => "ACTIVE_DATE",
                "sortDirection" => "desc", "size" => 200, "start" => 0 },
              PSN::Resources::Games::PURCHASED_HASH)
        .and_return(purchased_response(Array.new(200) { fixture("purchased_game") }))

      expect(games.purchased.first(3).size).to eq(3)
      expect(connection).to have_received(:graphql).once
    end
  end

  describe "#friends_who_play" do
    it "maps friend profiles from the web host to User models" do
      allow(connection).to receive(:graphql)
        .with("friendsWhoPlayRetrieveByConceptId", { "conceptId" => "10015869" },
              described_class::FRIENDS_WHO_PLAY_HASH, host: :web)
        .and_return(fixture("friends_who_play"))

      result = games.friends_who_play(10_015_869)
      expect(result.size).to eq(2)
      expect(result.first).to be_a(PSN::User)
      expect(result.first.online_id).to eq("player-one")
      expect(result.first.display_name).to eq("Player One")
      expect(result.first.avatar_url).to eq("https://example.com/avatar-one-large.png")
    end

    it "maps subscription and verification flags" do
      allow(connection).to receive(:graphql).and_return(fixture("friends_who_play"))

      first, second = games.friends_who_play(10_015_869)
      expect(first).to be_ps_plus
      expect(first).not_to be_verified
      expect(second).to be_verified
      expect(second).not_to be_ps_plus
    end

    it "leaves account_id nil and falls back to the small avatar" do
      allow(connection).to receive(:graphql).and_return(fixture("friends_who_play"))

      second = games.friends_who_play(10_015_869).last
      expect(second.account_id).to be_nil
      expect(second.avatar_url).to eq("https://example.com/avatar-two-small.png")
      expect(second.raw).to eq(fixture("friends_who_play").dig("data", "gameListFriendsOwningGame", "profiles").last)
    end

    it "returns an empty array when the payload has no profiles" do
      allow(connection).to receive(:graphql).and_return({ "data" => {} })

      expect(games.friends_who_play(10_015_869)).to eq([])
    end
  end
end
