# frozen_string_literal: true

RSpec.describe PSN::Resources::Trophies do
  subject(:trophies) { described_class.new(connection, users) }

  let(:connection) { instance_double(PSN::Connection) }
  let(:users) { instance_double(PSN::Resources::Users, account_id: "me") }

  describe "#titles" do
    it "returns lazy TrophyTitle objects" do
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/trophyTitles", { "limit" => 100, "offset" => 0 })
        .and_return({ "trophyTitles" => [fixture("trophy_title")], "totalItemCount" => 1 })

      result = trophies.titles.to_a
      expect(result.first).to be_a(PSN::TrophyTitle)
      expect(result.first.np_communication_id).to eq("NPWR20188_00")
    end
  end

  describe "#summary" do
    it "returns a TrophySummary" do
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/trophySummary", {})
        .and_return(fixture("trophy_summary"))

      expect(trophies.summary.level).to eq(401)
    end
  end

  describe "#earned" do
    def stub_trophy_calls(params)
      definition2 = fixture("trophy_definition").merge("trophyId" => 2, "trophyName" => "Hidden Gem")
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/npCommunicationIds/NPWR20188_00/trophyGroups/all/trophies", params)
        .and_return({ "trophies" => [fixture("trophy_definition"), definition2] })
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/npCommunicationIds/NPWR20188_00/trophyGroups/all/trophies", params)
        .and_return({ "trophies" => [fixture("trophy_earned")] })
    end

    it "merges definitions with earned status" do
      stub_trophy_calls({})
      result = trophies.earned(np_communication_id: "NPWR20188_00").to_a

      expect(result.size).to eq(2)
      expect(result[0].name).to eq("One Small Step")
      expect(result[0]).to be_earned
      expect(result[0].earned_at).to eq(Time.utc(2025, 1, 2, 20, 15, 0))
    end

    it "marks unearned trophies correctly" do
      stub_trophy_calls({})
      result = trophies.earned(np_communication_id: "NPWR20188_00").to_a

      expect(result[1].name).to eq("Hidden Gem")
      expect(result[1]).not_to be_earned
    end

    it "adds npServiceName=trophy for non-PS5 platforms" do
      stub_trophy_calls({ "npServiceName" => "trophy" })
      result = trophies.earned(np_communication_id: "NPWR20188_00", platform: "PS4").to_a
      expect(result.size).to eq(2)
    end

    it "omits npServiceName for PS5 titles" do
      stub_trophy_calls({})
      trophies.earned(np_communication_id: "NPWR20188_00", platform: "PS5").to_a
      expect(connection).to have_received(:get).twice
    end
  end

  describe "#title_summary" do
    it "chunks title IDs into batches of 5 per request" do
      allow(users).to receive(:account_id).with(nil).and_return("me")
      ids = %w[A_00 B_00 C_00 D_00 E_00 F_00]
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/titles/trophyTitles",
              { "npTitleIds" => "A_00,B_00,C_00,D_00,E_00" })
        .and_return({ "titles" => [fixture("title_trophy_summary")] })
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/titles/trophyTitles", { "npTitleIds" => "F_00" })
        .and_return({ "titles" => [fixture("title_trophy_summary")] })

      result = trophies.title_summary(title_ids: ids).to_a
      expect(result.size).to eq(2)
      expect(result.first).to be_a(PSN::TitleTrophySummary)
      expect(connection).to have_received(:get).twice
    end

    it "is lazy across batches and resolves the online ID" do
      allow(users).to receive(:account_id).with("friend").and_return("42")
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/42/titles/trophyTitles",
              { "npTitleIds" => "A_00,B_00,C_00,D_00,E_00" })
        .and_return({ "titles" => [fixture("title_trophy_summary")] })

      result = trophies.title_summary(online_id: "friend", title_ids: %w[A_00 B_00 C_00 D_00 E_00 F_00])
      expect(result.first(1).size).to eq(1)
      expect(connection).to have_received(:get).once # second batch never requested
    end
  end

  describe "#groups" do
    it "merges group definitions with the account's earned progress" do
      allow(users).to receive(:account_id).with(nil).and_return("me")
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/npCommunicationIds/NPWR20188_00/trophyGroups", {})
        .and_return({ "trophyGroups" => [fixture("trophy_group_definition")] })
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/npCommunicationIds/NPWR20188_00/trophyGroups", {})
        .and_return({ "trophyGroups" => [fixture("trophy_group_earned")] })

      result = trophies.groups(np_communication_id: "NPWR20188_00").to_a
      expect(result.size).to eq(1)
      expect(result.first).to be_a(PSN::TrophyGroup)
      expect(result.first.progress).to eq(83)
      expect(result.first.defined_counts).to eq(bronze: 24, silver: 12, gold: 6, platinum: 1)
    end

    it "sends npServiceName=trophy for pre-PS5 platforms" do
      allow(users).to receive(:account_id).with(nil).and_return("me")
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/npCommunicationIds/NPWR00001_00/trophyGroups",
              { "npServiceName" => "trophy" })
        .and_return({ "trophyGroups" => [fixture("trophy_group_definition")] })
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/users/me/npCommunicationIds/NPWR00001_00/trophyGroups",
              { "npServiceName" => "trophy" })
        .and_return({ "trophyGroups" => [] })

      result = trophies.groups(np_communication_id: "NPWR00001_00", platform: "PS4").to_a
      expect(result.first.earned_counts).to be_nil
    end
  end

  describe "#definitions" do
    it "returns lazy Trophy definitions without account context" do
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/npCommunicationIds/NPWR20188_00/trophyGroups/all/trophies", {})
        .and_return({ "trophies" => [fixture("trophy_definition")] })

      result = trophies.definitions(np_communication_id: "NPWR20188_00").to_a
      expect(result.first).to be_a(PSN::Trophy)
      expect(result.first.name).to eq("One Small Step")
      expect(result.first).not_to be_earned
    end

    it "adds npServiceName=trophy for non-PS5 platforms" do
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/npCommunicationIds/NPWR20188_00/trophyGroups/all/trophies",
              { "npServiceName" => "trophy" })
        .and_return({ "trophies" => [] })

      expect(trophies.definitions(np_communication_id: "NPWR20188_00", platform: "PS4").to_a).to eq([])
    end
  end

  describe "#group_definitions" do
    it "returns lazy TrophyGroup definitions without progress" do
      allow(connection).to receive(:get)
        .with(:mobile, "/api/trophy/v1/npCommunicationIds/NPWR20188_00/trophyGroups", {})
        .and_return({ "trophyGroups" => [fixture("trophy_group_definition")] })

      result = trophies.group_definitions(np_communication_id: "NPWR20188_00").to_a
      expect(result.first).to be_a(PSN::TrophyGroup)
      expect(result.first.group_id).to eq("default")
      expect(result.first.progress).to be_nil
    end
  end

  describe "#game_help_availability" do
    it "lists trophies with Game Help via metGetHintAvailability" do
      response = { "data" => { "hintAvailabilityRetrieve" => { "trophies" => [fixture("help_availability")] } } }
      allow(connection).to receive(:graphql)
        .with("metGetHintAvailability", { "npCommId" => "NPWR20188_00" },
              described_class::HELP_AVAILABILITY_HASH, headers: described_class::GAME_HELP_HEADERS)
        .and_return(response)

      result = trophies.game_help_availability(np_communication_id: "NPWR20188_00").to_a
      expect(result.size).to eq(1)
      expect(result.first).to be_a(PSN::TrophyHelpInfo)
      expect(result.first.uds_object_id).to eq("GATCHA_SECRET")
    end

    it "limits the check to specific trophy IDs when given" do
      response = { "data" => { "hintAvailabilityRetrieve" => { "trophies" => [] } } }
      allow(connection).to receive(:graphql)
        .with("metGetHintAvailability", { "npCommId" => "NPWR20188_00", "trophyIds" => %w[18 19] },
              described_class::HELP_AVAILABILITY_HASH, headers: described_class::GAME_HELP_HEADERS)
        .and_return(response)

      expect(trophies.game_help_availability(np_communication_id: "NPWR20188_00", trophy_ids: [18, 19]).to_a).to eq([])
    end

    it "returns no results when the envelope is missing" do
      allow(connection).to receive(:graphql).and_return({ "data" => nil })
      expect(trophies.game_help_availability(np_communication_id: "NPWR20188_00").to_a).to eq([])
    end
  end

  describe "#game_help" do
    let(:tips_variables) do
      { "npCommId" => "NPWR20188_00",
        "trophies" => [{ "trophyId" => "18", "udsObjectId" => "GATCHA_SECRET", "helpType" => "HINT" }] }
    end

    before do
      allow(connection).to receive(:graphql)
        .with("metGetTips", tips_variables, described_class::TIPS_HASH,
              headers: described_class::GAME_HELP_HEADERS)
        .and_return({ "data" => { "tipsRetrieve" => fixture("trophy_tips") } })
    end

    it "fetches tips for TrophyHelpInfo objects" do
      info = PSN::TrophyHelpInfo.from_api(fixture("help_availability"))
      help = trophies.game_help(np_communication_id: "NPWR20188_00", trophies: [info])
      expect(help).to be_a(PSN::GameHelp)
      expect(help).to be_access
      expect(help.tips.first.contents.first.display_name).to eq("Since 1995")
    end

    it "accepts plain hashes with symbol keys" do
      help = trophies.game_help(np_communication_id: "NPWR20188_00",
                                trophies: [{ trophy_id: 18, uds_object_id: "GATCHA_SECRET", help_type: "HINT" }])
      expect(help.tips.size).to eq(1)
    end
  end
end
