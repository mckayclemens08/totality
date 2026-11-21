-- Posting checks a post's media with this function, so signed-in users must be able to run it.
grant execute on function private.social_media_valid(jsonb, uuid) to authenticated;
