import { plainEntry, provisioningSite } from "./api.ts"

/**
 * One shell word, quoted so that nothing inside it can end the word: single
 * quotes make every byte literal, and a literal quote is spliced in closed.
 */
export function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}

/**
 * A flag and its value as one argument. The flag is a constant and stays bare;
 * the value is quoted, so one carrying a space or a metacharacter stays a single
 * word instead of becoming a second command.
 */
export function argPair(flag: string, value: string): string {
  return `${flag} ${shellQuote(value)}`
}

// Only the names nginx and certbot both accept, and nothing else: the whitelist
// already refuses every shell metacharacter -- `;`, `$`, a backtick, a newline, a
// space, quotes, `|`, `&`, `<`, `>`, brackets, `*`, `?`, `!`, `#`, `~` -- so
// there is no second blacklist to keep in step with it. Written case-explicit so
// the same source serves as the input's `pattern`, which HTML compiles without
// flags -- and under the `v` flag current browsers actually use for it, a bare
// `-` inside a class is a syntax error, so it is escaped here. An attribute whose
// pattern does not compile is dropped silently, which is why the two have to
// agree rather than merely look alike.
const HOSTNAME_SOURCE = "^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z]{2,63}$"

/** [HOSTNAME_SOURCE] as text, for the input's `pattern`, so the browser agrees with the panel. */
export const HOSTNAME_PATTERN = HOSTNAME_SOURCE

const HOSTNAME = new RegExp(HOSTNAME_SOURCE)

/**
 * Whether this is a domain name a certificate can be issued for, and therefore
 * safe to place in a command an operator runs as root. A single label is refused
 * as well: no CA issues for one, so a name without a dot is a typo rather than a
 * host that could be bound.
 */
export function validHostname(host: string): boolean {
  return HOSTNAME.test(host)
}

/**
 * TLS exceptions are an explicit operator choice, never inferred from an IP.
 * Each entry of `args` is one finished shell word -- a bare constant flag, or
 * [argPair] for a flag whose value comes from outside this module.
 */
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
