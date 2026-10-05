# frozen_string_literal: true

module PSN
  # Entry point. Authenticates with an NPSSO token or a saved refresh token
  # and exposes the PSN API as namespaced resources.
  #
  #   client = PSN::Client.new(npsso: "...")
  #   client.games.played.first(10)
  #   client.trophies.summary("a_friend")
  #   client.store.entitlements.to_a
  #
  # language: is sent as Accept-Language on every request (display strings
  # in some responses follow it).
  # on_token_refresh: is called with each new refresh token — persist it there
  # instead of polling #refresh_token, since Connection can rotate the token
  # mid-session when it recovers from a 401. Persist the token argument itself;
  # delivery order is unspecified if two threads rotate concurrently. If the
  # callback raises, the event is not re-delivered — rescue and recover via
  # #refresh_token.
  class Client
    def initialize(npsso: nil, refresh_token: nil, language: Connection::DEFAULT_LANGUAGE, on_token_refresh: nil)
      @auth = Auth.new(npsso: npsso, refresh_token: refresh_token, on_token_refresh: on_token_refresh)
      @connection = Connection.new(@auth, language: language)
    end

    def games = @games ||= Resources::Games.new(@connection, users)
    def trophies = @trophies ||= Resources::Trophies.new(@connection, users)
    def store = @store ||= Resources::Store.new(@connection)
    def profiles = @profiles ||= Resources::Profiles.new(@connection, users)
    def search = @search ||= Resources::Search.new(@connection)
    def catalog = @catalog ||= Resources::Catalog.new(@connection)
    def social = @social ||= Resources::Social.new(@connection, users)
    def devices = @devices ||= Resources::Devices.new(@connection)
    def media = @media ||= Resources::Media.new(@connection)
    def groups = @groups ||= Resources::Groups.new(@connection)
    def browse = @browse ||= Resources::Browse.new(@connection)

    # Triggers authentication if it has not happened yet.
    def access_token = @auth.access_token

    def access_token_expires_at = @auth.expires_at

    # Persist this (it rotates) to reconstruct the client without a fresh NPSSO.
    def refresh_token = @auth.refresh_token

    private

    def users = @users ||= Resources::Users.new(@connection)
  end
end
