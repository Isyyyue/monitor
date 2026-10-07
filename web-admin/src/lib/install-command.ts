import { plainEntry, provisioningSite } from "./api.ts"

/** TLS exceptions are an explicit operator choice, never inferred from an IP. */
export function installScriptCommand(site: string, args: string[], acceptUnverified?: boolean): string {
  site = provisioningSite(site)
  if (!site) return ""
  const insecure = !!plainEntry(site) || acceptUnverified === true
  const tls = insecure ? ["--insecure"] : acceptUnverified === false ? ["--verify-tls"] : []
  const curlFlag = insecure && site.startsWith("https:") ? " -k" : ""
  // A failed download must not run an empty script and report success. The
  // temporary path is unique, cleaned up, and never shared with another run.
  return `(set -eu; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL${curlFlag} '${site}/install.sh' -o "$f"; sh "$f" ${args.concat(tls).join(" ")})`
}
