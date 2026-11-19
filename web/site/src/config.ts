// Filled in at build time from the build's environment (see build.mjs). The key is Supabase's public
// "publishable" key, which every app install carries. No secret belongs here.
declare const __SUPABASE_URL__: string;
declare const __SUPABASE_KEY__: string;

export const config = {
  url: __SUPABASE_URL__,
  key: __SUPABASE_KEY__,
  /** The account's sign-in address, the same one the iPhone app makes from a username. */
  domain: "@totality.invalid",
};
export const isConfigured = (): boolean => config.url.startsWith("https://") && config.key.length > 0;
