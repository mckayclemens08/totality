# Totality News v1

News gives people a chronological list of headlines from feeds they follow, a Discover view for top stories and topics, and a saved reading list. Articles show the publisher, headline, original summary when provided, and a link. Open hands the link to a private tab in Totality Web through the app and module registry. Discovery entries show publisher metadata and the original link.

## Screens

- **Latest** combines followed RSS and Atom feeds. Pull to refresh. One failed feed leaves the others usable and the last loaded copy visible.
- **Discover** starts with a general top-stories query. A topic search goes directly to the GDELT Project and names that destination alongside the search box.
- **Saved** holds the headline, summary, source and original link. Save and remove are available beside the headline. The list is encrypted locally with the account’s content key.
- **Sources** lists the built-in feeds and accepts a custom feed URL. Follow and unfollow take effect on this device.
- **Home** offers a News tile in three sizes and finds loaded and saved headlines through local search.

The UI follows the existing Totality theme and raised controls. First load, an empty feed or reading list, partial failure, and retry each have a dedicated state.

## Sources and terms

Reviewed November 27, 2026. Default feeds are deliberately limited to sources with a clear free-use basis. Publishers retain attribution. The app shows feed text and links, skips remote media, and does not republish full articles.

| Source | Feed and basis |
| --- | --- |
| NASA News Releases | [RSS directory](https://www.nasa.gov/rss-feeds/) and [NASA media guidelines](https://www.nasa.gov/nasa-brand-center/images-and-media/). Use NASA-authored release metadata and links with attribution. Omit NASA marks and third-party media. |
| U.S. Geological Survey | [Significant Earthquakes Atom feed](https://earthquake.usgs.gov/earthquakes/feed/v1.0/atom.php) and [USGS licensing guidance](https://www.usgs.gov/data-management/data-licensing). Use agency-produced event titles and public data with attribution. |
| National Weather Service, Idaho | [Alerts service](https://www.weather.gov/documentation/services-web-alerts) and [NWS reuse terms](https://www.weather.gov/disclaimer). Attribute the agency, link to the official alert, and preserve agency wording where displayed. |
| GDELT Project | [DOC 2.0 documentation](https://blog.gdeltproject.org/gdelt-doc-2-0-api-debuts/) and [terms](https://www.gdeltproject.org/about.html#termsofuse). Credit and link to GDELT. Use article URLs, headlines, domains and dates. |

[BBC](https://www.bbc.com/pages/terms-of-use), [NPR](https://www.npr.org/about-npr/179876898/terms-of-use), and [Guardian](https://www.theguardian.com/help/feeds) feeds have use restrictions and are omitted from the defaults. The user may subscribe to their own feeds where permitted. NewsAPI.org, GNews, paid or restricted publisher APIs, Reddit, and Google News RSS are excluded.

## Data and cost

The phone contacts publishers and GDELT directly. The Totality server receives no feed lists, topic queries, reading list, or article opens from News. Publishers receive requests addressed to them and GDELT receives topics the user submits. News uses no paid key, backend, database migration, or media service. Subscriptions and saved articles are account-scoped and encrypted on this device. Article bodies remain with their publishers. Expect HTTPS for feeds and links under the app’s normal transport policy.
