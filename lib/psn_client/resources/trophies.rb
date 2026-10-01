# frozen_string_literal: true

module PSN
  module Resources
    class Trophies
      TITLES_PATH = "/api/trophy/v1/users/%s/trophyTitles"
      SUMMARY_PATH = "/api/trophy/v1/users/%s/trophySummary"
      DEFINITIONS_PATH = "/api/trophy/v1/npCommunicationIds/%s/trophyGroups/all/trophies"
      EARNED_PATH = "/api/trophy/v1/users/%s/npCommunicationIds/%s/trophyGroups/all/trophies"
      # trophyTitles caps limit at 800 (verified live: 800 works, 801 returns
      # HTTP 400); this page size is well under the maximum to keep lazy reads
      # (e.g. .first(n)) from over-fetching.
      PAGE_SIZE = 100
      TITLE_SUMMARY_PATH = "/api/trophy/v1/users/%s/titles/trophyTitles"
      TITLE_IDS_PER_REQUEST = 5
      GROUPS_DEFINITIONS_PATH = "/api/trophy/v1/npCommunicationIds/%s/trophyGroups"
      GROUPS_EARNED_PATH = "/api/trophy/v1/users/%s/npCommunicationIds/%s/trophyGroups"

      # Game Help (PS+ trophy hints) persisted queries. Undocumented; Sony
      # can change hashes and shape at any time — verify with bin/smoke.
      # Requests must identify as the PlayStation App or Sony rejects them.
      GAME_HELP_HEADERS = { "apollographql-client-name" => "PlayStationApp-Android" }.freeze
      HELP_AVAILABILITY_OPERATION = "metGetHintAvailability"
      HELP_AVAILABILITY_HASH = "71bf26729f2634f4d8cca32ff73aaf42b3b76ad1d2f63b490a809b66483ea5a7"
      TIPS_OPERATION = "metGetTips"
      TIPS_HASH = "93768752a9f4ef69922a543e2209d45020784d8781f57b37a5294e6e206c5630"

      def initialize(connection, users)
        @connection = connection
        @users = users
      end

      def titles(online_id = nil)
        account_id = @users.account_id(online_id)
        paginator = Paginator.offset(page_size: PAGE_SIZE) do |limit, offset|
          response = @connection.get(:mobile, format(TITLES_PATH, account_id),
                                     { "limit" => limit, "offset" => offset })
          [response["trophyTitles"] || [], response["totalItemCount"]]
        end
        paginator.map { |title| TrophyTitle.from_api(title) }
      end

      def summary(online_id = nil)
        account_id = @users.account_id(online_id)
        TrophySummary.from_api(@connection.get(:mobile, format(SUMMARY_PATH, account_id), {}))
      end

      # Trophy progress for specific title IDs (CUSA/PPSA...). The API caps
      # each request at 5 IDs, so larger lists are fetched in lazy batches.
      def title_summary(online_id: nil, account_id: nil, title_ids:)
        acc_id = account_id || @users.account_id(online_id)
        title_ids.each_slice(TITLE_IDS_PER_REQUEST).lazy.flat_map do |batch|
          response = @connection.get(:mobile, format(TITLE_SUMMARY_PATH, acc_id),
                                     { "npTitleIds" => batch.join(",") })
          (response["titles"] || []).map { |title| TitleTrophySummary.from_api(title) }
        end
      end

      # All trophies for one title, each merged with the user's earned status.
      def earned(online_id = nil, np_communication_id:, platform: nil)
        account_id = @users.account_id(online_id)
        params = service_params(platform)
        definitions = @connection.get(:mobile, format(DEFINITIONS_PATH, np_communication_id), params)
        earned = @connection.get(:mobile, format(EARNED_PATH, account_id, np_communication_id), params)
        merge(definitions["trophies"] || [], earned["trophies"] || []).lazy
      end

      # Trophy groups for one title (base game is "default", DLC packs are
      # "001", "002", ...), each merged with the account's progress.
      def groups(online_id = nil, np_communication_id:, platform: nil)
        account_id = @users.account_id(online_id)
        params = service_params(platform)
        definitions = @connection.get(:mobile, format(GROUPS_DEFINITIONS_PATH, np_communication_id), params)
        earned = @connection.get(:mobile, format(GROUPS_EARNED_PATH, account_id, np_communication_id), params)
        merge_groups(definitions["trophyGroups"] || [], earned["trophyGroups"] || []).lazy
      end

      # Trophy definitions for a title with no account context — works for games
      # the account has never played (where #earned has nothing to merge).
      def definitions(np_communication_id:, platform: nil)
        response = @connection.get(:mobile, format(DEFINITIONS_PATH, np_communication_id),
                                   service_params(platform))
        (response["trophies"] || []).lazy.map { |trophy| Trophy.from_api(trophy) }
      end

      # Trophy group definitions (base game "default", DLC "001"...) without
      # account progress.
      def group_definitions(np_communication_id:, platform: nil)
        response = @connection.get(:mobile, format(GROUPS_DEFINITIONS_PATH, np_communication_id),
                                   service_params(platform))
        (response["trophyGroups"] || []).lazy.map { |group| TrophyGroup.from_api(group) }
      end

      # Trophies in a title that have Game Help available. Pass trophy_ids
      # to limit the check; the results feed straight into #game_help.
      def game_help_availability(np_communication_id:, trophy_ids: nil)
        variables = { "npCommId" => np_communication_id }
        variables["trophyIds"] = trophy_ids.map(&:to_s) if trophy_ids
        response = @connection.graphql(HELP_AVAILABILITY_OPERATION, variables,
                                       HELP_AVAILABILITY_HASH, headers: GAME_HELP_HEADERS)
        trophies = response.dig("data", "hintAvailabilityRetrieve", "trophies") || []
        trophies.lazy.map { |t| TrophyHelpInfo.from_api(t) }
      end

      # The Game Help content itself. trophies takes TrophyHelpInfo objects
      # (from #game_help_availability) or hashes with :trophy_id,
      # :uds_object_id and :help_type. GameHelp#access? is false without PS+.
      def game_help(np_communication_id:, trophies:)
        variables = { "npCommId" => np_communication_id,
                      "trophies" => trophies.map { |t| help_request(t) } }
        response = @connection.graphql(TIPS_OPERATION, variables, TIPS_HASH,
                                       headers: GAME_HELP_HEADERS)
        GameHelp.from_api(response.dig("data", "tipsRetrieve") || {})
      end

      private

      # PS5 titles use the default trophy2 service; everything older needs
      # an explicit npServiceName=trophy.
      def service_params(platform)
        return {} if platform.nil? || platform.to_s.upcase.start_with?("PS5")

        { "npServiceName" => "trophy" }
      end

      def help_request(trophy)
        if trophy.is_a?(TrophyHelpInfo)
          { "trophyId" => trophy.trophy_id, "udsObjectId" => trophy.uds_object_id,
            "helpType" => trophy.help_type }
        else
          { "trophyId" => trophy[:trophy_id].to_s, "udsObjectId" => trophy[:uds_object_id],
            "helpType" => trophy[:help_type] }
        end
      end

      def merge(definitions, earned)
        earned_by_id = earned.to_h { |t| [t["trophyId"], t] }
        definitions.map { |d| Trophy.from_api(d.merge(earned_by_id[d["trophyId"]] || {})) }
      end

      def merge_groups(definitions, earned)
        earned_by_id = earned.to_h { |g| [g["trophyGroupId"], g] }
        definitions.map { |d| TrophyGroup.from_api(d.merge(earned_by_id[d["trophyGroupId"]] || {})) }
      end
    end
  end
end
