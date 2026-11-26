## Social: better tags
- `social_top_tags` replaced (new migration): a tag needs 3+ posts from 2+ people in 30 days; at most 8, ranked by use then recency.
- Post detail: #tags in the text are tappable (custom `totality-tag://` link plus `openURL`); the separate tag line shows only tags not already in the text.
- Tapping switches to For You filtered to that tag; a non-top tag gets its own chip while filtered, and All clears it.
- Tests: link/tag-line helpers in SocialModelTests.

Mockup: https://claude.ai/artifact/HZqaogNbr9BdhZBYQyWNKD

## Decisions I made
- Tap goes to the For You filter for any tag (no separate tag-search screen).
- The feed card has no tag line, and its body sits inside the open-post tap, so only the detail view got tappable tags.
- Migration needs applying to Supabase (no schema change, function only).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
