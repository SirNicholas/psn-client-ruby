# psn-client-ruby

Unofficial Ruby client for the PlayStation Network API: games played,
trophies earned, and entitlements.

## Installation

```ruby
gem "psn-client-ruby"
```

Requires Ruby >= 3.2.

## Authentication

PSN has no public API; this gem uses the same OAuth flow as the official
mobile app. You need an **NPSSO token**: sign in at playstation.com, then
visit <https://ca.account.sony.com/api/v1/ssocookie> (or use a helper
browser extension that fetches it for you). NPSSO tokens last about two
months.

```ruby
require "psn_client"

client = PSN::Client.new(npsso: "your-npsso")

# Persist client.refresh_token (lasts ~2 months, rotates on refresh) and
# skip the NPSSO next time:
client = PSN::Client.new(refresh_token: saved_token)

# language: is sent as Accept-Language on every request (default "en-US").
# on_token_refresh: is a push-based alternative to polling client.refresh_token —
# it's called with each new refresh token as it rotates, initial exchange included.
# A two-argument callback also receives the new access token's expiry (a Time);
# one-argument callbacks like ->(token) { ... } keep working.
client = PSN::Client.new(
  refresh_token: saved_token,
  language: "en-GB",
  on_token_refresh: ->(token, access_expires_at) { TokenStore.save(token, access_expires_at) }
)

client.access_token_expires_at # current access token's expiry (nil until first auth)

client.games.played.total  # server-reported count, without fetching every page
```

## Usage

Paged list calls return `PSN::Collection` — still lazy, so `.first(n)` only
fetches the pages it needs and `.to_a` fetches everything — with `#total`
for the server-reported item count on offset-paged endpoints (`nil` on
cursor-paged ones). Single-request lists (like `games.library`, `store.wishlist`,
and per-title trophy lists) return plain `Enumerator::Lazy` without `#total`.
Every object exposes `#raw` with the untouched API response.

```ruby
# Games played (any account whose privacy settings allow it)
client.games.played.first(10).each { |g| puts "#{g.name} [#{g.platform}]" }
client.games.played(online_id: "a_friend").to_a

# Game library and purchases (authenticated account only, GraphQL)
client.games.library.to_a                 # owned + subscription titles
client.games.purchased.first(20)          # games-only storefront view
client.games.friends_who_play(concept_id) # => [PSN::User] friends playing a concept

# Profiles
client.profiles.find                      # authenticated account
client.profiles.find("a_friend")          # avatar, PS Plus, presence, trophy level
client.profiles.find_by_account_id("1234567890")  # friends lists give bare IDs
client.profiles.account_summary                   # PS+/EA Play/Ubisoft+ states

# Social graph and presence
client.social.friends.first(10)           # account IDs (lazy), as bare strings
client.social.presence("a_friend")        # => PSN::Presence: online?, platform, now_playing
client.social.friend_requests.to_a        # incoming requests (account IDs)
client.social.blocked.to_a                # blocked account IDs
client.social.friendship("a_friend")      # => PSN::FriendshipSummary
client.social.available_to_play           # PROVISIONAL: raw availability list

# Devices (authenticated account only)
client.devices.all                        # => [PSN::Device] consoles/devices on the account
client.devices.storage(platform: "PS5")   # => [PSN::ConsoleStorage]

# Profile extras
client.profiles.shareable_link            # => PSN::ShareableLink (URL + QR code)
client.profiles.find.region               # => "GB" — decoded from the profile npId

# Media gallery (authenticated account only)
client.media.captures.first(10)        # PROVISIONAL: raw capture hashes (lazy)
client.media.download_url(ugc_id)      # PROVISIONAL: raw tokenized-URL hash

# Message groups (read-only, authenticated account only)
client.groups.all.first(10)                 # => PSN::Group DMs and group chats (lazy)
client.groups.find(group_id)                # => PSN::Group with members + latest message
client.groups.messages(group_id).first(20)  # => PSN::GroupMessage, newest first (lazy)

# Trophies
client.trophies.summary                                  # level, counts
client.trophies.titles.to_a                              # per-game progress
client.trophies.earned(np_communication_id: "NPWR20188_00")
client.trophies.earned("a_friend", np_communication_id: "NPWR00000_00", platform: "PS4")
client.trophies.title_summary(title_ids: %w[PPSA01325_00 CUSA13323_00])
client.trophies.groups(np_communication_id: "NPWR20188_00")  # base game vs DLC
client.trophies.definitions(np_communication_id: "NPWR20188_00")       # trophy list, no account needed
client.trophies.group_definitions(np_communication_id: "NPWR20188_00") # trophy groups, no account needed

# Purchases and wishlist (authenticated account only)
# client.store.transactions raises PSN::APIError — Sony decommissioned the endpoint
client.store.entitlements.to_a       # everything owned incl. free claims (PS4/PS5)
client.store.wishlist.to_a           # store wishlist incl. unreleased concepts

# Search the store and players
client.search.games("astro bot").first(5)         # => PSN::CatalogItem (lazy)
client.search.games("horizon", domain: :add_ons)  # DLC search
client.search.users("a_friend").first(5)          # => PSN::UserSearchResult (lazy)

# Store catalog (anonymous web-store data)
product = client.catalog.product("UP9000-PPSA01325_00-...")   # => PSN::StoreProduct
client.catalog.concept(product.concept_id)                    # => PSN::StoreConcept
client.catalog.pricing(product.concept_id)                    # => PSN::Price or nil
client.catalog.product_rating(product.id)                     # => PSN::StarRating or nil
client.catalog.category(:ps5_games).first(10)                 # browse store categories
client.catalog.add_ons("PPSA01325_00").first(10)              # DLC for a title
client.catalog.content_rating(product.concept_id)             # => PSN::ContentRating or nil
client.catalog.media(product.concept_id)                      # => [PSN::MediaItem]
client.catalog.compatibility_notices(product.concept_id)      # => PSN::CompatibilityNotices
client.catalog.legal_text(product.concept_id)                 # => PSN::LegalText
client.catalog.editions(product.concept_id)                   # => [PSN::Edition]
client.catalog.concept_for_product(product.id)                # => PSN::StoreConcept
client.catalog.add_ons_by_concept(product.concept_id).first(10)  # DLC keyed by concept
client.catalog.plus_offers(:extra)                             # => [PSN::PlusOffer]
client.catalog.concept_for_title("CUSA01433_00")                    # => [PSN::TitleConcept]
client.catalog.game_info("10015869")                              # product-page slices
client.catalog.accessibility("10015869")                          # accessibility notices by platform
client.catalog.media_carousel("10015869")                         # product-page media carousel
client.catalog.upsell("10015869")                                 # upsell editions with store CTAs

# Store browse (EMS)
browse = client.browse                                            # app store browse tree
home = browse.experience
views = browse.views(home.nav_items.first.view_collection_id, experience_id: home.id)
client.browse.grid(PSN::Resources::Catalog::CATEGORIES[:ps5_games]).first(5)
client.browse.facets(PSN::Resources::Catalog::CATEGORIES[:ps5_games]).facets.map(&:display_name)
client.browse.default_view("<category-uuid>", localized_key_id: "cat.gma....", experience_id: home.id)
client.browse.strand("<strand-uuid>")

# Trophy Game Help (PS+ hints)
infos = client.trophies.game_help_availability(np_communication_id: "NPWR20188_00")
help  = client.trophies.game_help(np_communication_id: "NPWR20188_00", trophies: infos.first(2))
help.access?  # false without a PS+ subscription
```

`games.purchased` and `store.entitlements` overlap but answer different
questions: `purchased` is the games-only library view (artwork,
`downloadable?`, `pre_order?`), and `entitlements` is the complete ownership
ledger down to DLC and free claims.

Amounts are integer minor units (`6999` + `"GBP"` = £69.99).

### Errors

All errors subclass `PSN::Error` (`#response` has status and body):
`AuthenticationError`, `PrivacyError` (target account is private),
`NotFoundError`, `RateLimitError` (`#retry_after`), `APIError`. Rate limits
are not retried automatically: a 429 raises `RateLimitError` immediately
with `#retry_after` so the caller decides when to retry.

## Development

```
bundle install
bundle exec rake        # rspec + rubocop + rbs validate + steep
ruby bin/smoke          # live-API check; needs PSN_NPSSO or PSN_REFRESH_TOKEN
```

Note: the transaction/entitlement endpoints, the GraphQL persisted queries
and the legacy profile endpoint are undocumented and may change; they live
in `lib/psn_client/resources/store.rb`, `lib/psn_client/resources/games.rb`,
`lib/psn_client/resources/profiles.rb`, `lib/psn_client/resources/search.rb`,
`lib/psn_client/resources/catalog.rb`, `lib/psn_client/resources/browse.rb`
(`client.browse` — EMS store browse: experience nav, views, category grids
with facets, strands) and the Game Help queries in
`lib/psn_client/resources/trophies.rb` if they need updating.

## License

MIT
