// The website's ModuleRegistry: how one module offers its content to another without either importing the
// other (module rule 7). A module registers what it can lend; another asks by its own name and gets
// ContentRefs back, shaped exactly as Swift encodes them.
export interface ContentRef {
  module: string; kind: string; id: string; keyRef: string; preview: { title: string; thumbnailKey?: string };
}
export interface Ctx { token: () => Promise<string>; userId: string }
type Provider = { module: string; for: string[]; attachable: (ctx: Ctx) => Promise<ContentRef[]> };

const providers: Provider[] = [];
export const register = (p: Provider): void => { providers.push(p); };
/** Everything other modules offer to `module`, for the "Attach from …" pickers. A provider that fails is left out. */
export async function attachable(module: string, ctx: Ctx): Promise<ContentRef[]> {
  const out: ContentRef[] = [];
  for (const p of providers.filter((x) => x.for.includes(module))) { try { out.push(...(await p.attachable(ctx))); } catch { /* left out */ } }
  return out;
}
