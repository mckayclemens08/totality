# Totality News v1

News gives people a chronological list of headlines from feeds they follow, a topic search screen, and a saved reading list. Articles show the publisher, headline, original summary when provided, and a link. Open hands the link to a private tab in Totality Web through the app and module registry. Discovery entries show publisher metadata and the original link.

## Screens

- **Today** combines followed RSS and Atom feeds. It leads with general top stories when GDELT is available, then mixes in followed headlines. If discovery is unavailable, the newest followed story leads. Today gives each available publisher a turn before repeating a source, with local editorial illustrations for the lead and story rows. Tap any headline to read it. Pull to refresh. One failed feed leaves the others usable and the last loaded copy visible.
- **Search** starts with a general top-stories query. A topic search goes directly to the GDELT Project and names that destination alongside the search box.
- **Saved** holds the headline, summary, source and original link. Save and remove are available beside the headline. The list is encrypted locally with the account’s content key.
- **Following** shows publishers by name with Follow and Unfollow controls. Search by name through the [Wikidata public directory](https://www.wikidata.org/wiki/Help:Data_access), or enter a publisher’s website. News tries an advertised public feed and falls back to GDELT headline links. A publisher with neither may have no stories to show. A followed story also offers an Unfollow action. The publisher directory manages feed addresses internally.
- **Home** offers a News tile in three sizes and finds loaded and saved headlines through local search.

The UI follows the existing Totality theme and raised controls. First load, an empty feed or reading list, partial failure, and retry each have a dedicated state.

## Sources and terms

Reviewed November 27, 2026. Default feeds are deliberately limited to sources with a clear free-use basis. Publishers retain attribution. The app shows feed text and links, skips remote media, and does not republish full articles.

| Source | Feed and basis |
| --- | --- |
| NASA News Releases | [RSS directory](https://www.nasa.gov/rss-feeds/) and [NASA media guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/). Use NASA-authored release metadata and links with attribution. Omit NASA marks and third-party media. |
| U.S. Geological Survey | [Significant Earthquakes Atom feed](https://earthquake.usgs.gov/earthquakes/feed/v1.0/atom.php) and [USGS licensing guidance](https://www.usgs.gov/data-management/data-licensing). Use agency-produced event titles and public data with attribution. |
| National Weather Service, Idaho | [Alerts service](https://www.weather.gov/documentation/services-web-alerts) and [NWS reuse terms](https://www.weather.gov/disclaimer). Attribute the agency, link to the official alert, and preserve agency wording where displayed. |
| Federal Reserve | Optional. [Press release feed](https://www.federalreserve.gov/feeds/feeds.htm) and [reuse terms](https://www.federalreserve.gov/disclaimer.htm). Credit the Board and use public-domain release metadata. |
| U.S. Census Bureau | Optional. [News release feed](https://www.census.gov/about/contact-us/feeds.html) and [public access policy](https://www2.census.gov/foia/ds_policies/ds027.pdf). Credit the agency and show its release metadata and links. |
| GDELT Project | [DOC 2.0 documentation](https://blog.gdeltproject.org/gdelt-doc-2-0-api-debuts/) and [terms](https://www.gdeltproject.org/about.html#termsofuse). Credit and link to GDELT. Use article URLs, headlines, domains and dates. |

[BBC](https://www.bbc.com/pages/terms-of-use), [NPR](https://www.npr.org/about-npr/179876898/terms-of-use), and [Guardian](https://www.theguardian.com/help/feeds) feeds have use restrictions and are omitted from the defaults. NewsAPI.org, GNews, paid or restricted publisher APIs, Reddit, and Google News RSS are excluded.

## Data and cost

The phone contacts publishers, Wikidata, and GDELT directly. The Totality server receives no feed lists, topic queries, reading list, or article opens from News. Publishers receive requests addressed to them and GDELT receives topics the user submits. News uses no paid key, backend, database migration, or media service. Subscriptions and saved articles are account-scoped and encrypted on this device. Article bodies remain with their publishers. Expect HTTPS for feeds and links under the app’s normal transport policy.
