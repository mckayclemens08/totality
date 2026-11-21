-- Posts are inserted column by column (title, body, tags), so the new media column needs its own grant,
-- or every photo or audio post is refused.
grant insert (media) on public.social_posts to authenticated;
