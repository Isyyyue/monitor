import manifest from "../../theme.json"
import { api } from "@/lib/api"

/**
 * The operator's settings over the defaults declared in theme.json, which the
 * hub does not store. A saved value of another type -- left by an older version
 * of this theme -- counts as unsaved. Any failure, a hub predating settings (404)
 * included, renders the defaults rather than an error.
 */
export function loadConfig(): Promise<Record<string, unknown>> {
  // ponytail: checks the type only; a select or a ranged number would need the
  // option and min/max checks the panel applies.
  const pick = (saved: Record<string, unknown>) =>
    Object.fromEntries(
      manifest.config.map((f) => [f.key, typeof saved[f.key] === typeof f.default ? saved[f.key] : f.default]),
    )
  return api<Record<string, unknown>>(`/themes/${manifest.short}/config`).then(pick).catch(() => pick({}))
}
