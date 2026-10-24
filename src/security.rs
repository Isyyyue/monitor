//! Security response headers and the trust boundary between a theme and the panel.
//!
//! A theme is third-party code that the hub serves from its own origin. That is
//! unavoidable for a page whose whole job is to render someone else's markup and
//! assets, but it must not extend to the panel: a script running on the public
//! page shares the origin with `/admin` and `/api/*`, and same-origin scripts can
//! read `/api/nodes` (every node token in the clear) and `/api/db/backup` (the
//! whole database) regardless of `HttpOnly`, which stops a script reading a cookie
//! but not sending a request.
//!
//! Two layers close that:
//!
//! 1. Every response carries `Content-Security-Policy`. The panel gets the strict
//!    one -- its scripts are all bundled and hashed by Vite, so it needs no
//!    inline script and no nonce. The public page needs an inline script for a
//!    theme that injects one (the bundled miku theme does, see
//!    `scripts/theme-miku.sh`), so it is issued a per-response nonce and inline
//!    script is allowed only when it carries that nonce. `unsafe-inline` is never
//!    granted, which means a theme's `<script>` must be rewritten by the hub to
//!    carry the nonce; see [`nonce_into`].
//!
//! 2. `frame-ancestors 'none'` plus `X-Frame-Options: DENY` stop the panel being
//!    framed, which is what makes clickjacking a session-bearing admin into
//!    deleting a node or reissuing a token impossible.
//!
//! The nonce is per response and never reused, so a theme cannot learn it from an
//! earlier page load and cannot forge it.

use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};

/// Header values that apply to every response the hub sends.
///
/// `nosniff` is what keeps a `application/json` reply from being sniffed into
/// HTML, and `no-referrer` keeps a theme's outgoing requests from carrying the
/// panel's URL to a third party.
const COMMON: &[(&str, &str)] = &[
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "no-referrer"),
    // No cross-origin isolation is needed, but the panel must not be embedded and
    // must not load plugin content.
    ("Cross-Origin-Opener-Policy", "same-origin"),
];

/// The panel's policy: everything from the origin itself, no inline script, no
/// inline style, no eval. Vite emits external bundles only, so this costs nothing.
const ADMIN_CSP: &str = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; \
     img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; \
     media-src 'self' blob:; object-src 'none'; base-uri 'none'; form-action 'self'; \
     frame-ancestors 'none'";

/// The public page's policy. `script-src` admits the nonce issued for this
/// response and nothing else inline; a theme's own scripts must be rewritten to
/// carry it, and a theme that ships a script without one simply does not run.
///
/// `style-src 'unsafe-inline'` is kept: themes inject stylesheets and inline
/// style attributes, and a style cannot read data or send a request.
const THEME_CSP_PREFIX: &str = "default-src 'self'; script-src 'self' 'nonce-";
const THEME_CSP_SUFFIX: &str = "'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; \
     font-src 'self' data:; connect-src 'self' ws: wss:; media-src 'self' blob:; \
     object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'";

/// A fresh CSP nonce: 128 bits, hex. Long enough that guessing it is not a
/// strategy, and hex so it needs no escaping inside an HTML attribute.
pub fn nonce() -> String {
    hex::encode(rand::random::<[u8; 16]>())
}

/// Adds the headers every response carries.
///
/// Applied as the outermost layer, so it also reaches API replies that never pass
/// through a renderer. It never overwrites a `Content-Security-Policy`: the
/// renderers that know what a response is -- the panel, the public page -- set
/// the policy that fits, and this layer runs after them.
pub fn harden(mut response: Response) -> Response {
    let headers = response.headers_mut();
    for (name, value) in COMMON {
        // `insert` rather than `append`: a duplicate security header is read
        // inconsistently across browsers. `entry` so a renderer's own value wins.
        if let (Ok(name), Ok(value)) = (name.parse::<header::HeaderName>(), HeaderValue::from_str(value)) {
            headers.entry(name).or_insert(value);
        }
    }
    response
}

/// The panel's headers: the common set plus the strict policy.
pub fn harden_admin(response: Response) -> Response {
    let mut response = harden(response);
    if let Ok(value) = HeaderValue::from_str(ADMIN_CSP) {
        response.headers_mut().insert(header::CONTENT_SECURITY_POLICY, value);
    }
    response
}

/// The public page's headers, with the nonce its inline scripts must carry.
pub fn harden_theme(response: Response, nonce: &str) -> Response {
    let mut response = harden(response);
    let policy = format!("{THEME_CSP_PREFIX}{nonce}{THEME_CSP_SUFFIX}");
    if let Ok(value) = HeaderValue::from_str(&policy) {
        response.headers_mut().insert(header::CONTENT_SECURITY_POLICY, value);
    }
    response
}

/// Rewrites a theme's HTML so its inline scripts carry `nonce`.
///
/// The hub cannot know which `<script>` a theme meant to run, so it admits the
/// ones that are inline and leaves the ones with a `src` alone -- those are
/// already covered by `script-src 'self'`. A tag that already carries a nonce is
/// left untouched: a theme may have been built against this scheme already.
///
/// This is a byte-level insertion, not a parse: it looks for `<script` and the
/// next `>`, which is exactly the boundary the HTML tokenizer uses for a start
/// tag. Text inside a comment or a `<template>` would also match, but inserting a
/// nonce there is harmless -- the nonce is not a secret the page must keep from
/// itself, only a value an injected script cannot guess ahead of time.
pub fn nonce_into(html: Vec<u8>, nonce: &str) -> Vec<u8> {
    const TAG: &[u8] = b"<script";
    let mut out = Vec::with_capacity(html.len() + 64);
    let mut rest: &[u8] = &html;
    loop {
        let Some(at) = find(rest, TAG) else {
            out.extend_from_slice(rest);
            return out;
        };
        let (before, from_tag) = rest.split_at(at);
        out.extend_from_slice(before);
        // The tag runs to the next `>`, or to the end if the document is
        // malformed and there is none.
        let Some(close) = from_tag.iter().position(|b| *b == b'>') else {
            out.extend_from_slice(from_tag);
            return out;
        };
        let (tag, after) = from_tag.split_at(close);
        let lower = tag.to_ascii_lowercase();
        let has_src = find(&lower, b" src=").is_some() || find(&lower, b" src>").is_some();
        let has_nonce = find(&lower, b" nonce=").is_some();
        if has_src || has_nonce {
            out.extend_from_slice(tag);
        } else {
            // Insert before the `>` that closes the start tag, keeping any
            // existing attributes intact. `tag` excludes the `>` itself, so the
            // nonce lands inside the tag rather than after it.
            out.extend_from_slice(tag);
            out.extend_from_slice(b" nonce=\"");
            out.extend_from_slice(nonce.as_bytes());
            out.push(b'"');
        }
        // `after` begins with the `>` that closed the tag; re-emit it exactly
        // once. Emitting it here and again below would double every tag.
        out.push(b'>');
        rest = &after[1..];
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|window| window == needle)
}

/// A refusal that still carries the security headers, for the paths that answer
/// without going through the theme or panel renderers.
pub fn refusal(status: StatusCode, text: impl Into<String>) -> Response {
    harden((status, text.into()).into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_nonce_is_long_random_and_hex() {
        let a = nonce();
        let b = nonce();
        assert_eq!(a.len(), 32, "128 bits of hex");
        assert!(a.bytes().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(a, b, "a nonce must not repeat between responses");
    }

    #[test]
    fn inline_scripts_get_the_nonce_and_external_ones_are_left_alone() {
        let html = br#"<head><script>alert(1)</script><script src="/a.js"></script></head>"#;
        let out = String::from_utf8(nonce_into(html.to_vec(), "abc")).unwrap();
        assert!(out.contains(r#"<script nonce="abc">alert(1)</script>"#), "{out}");
        assert!(out.contains(r#"<script src="/a.js"></script>"#), "a src tag needs no nonce: {out}");
    }

    #[test]
    fn a_tag_that_already_carries_a_nonce_is_not_doubled() {
        let html = br#"<script nonce="old">x</script>"#;
        let out = String::from_utf8(nonce_into(html.to_vec(), "new")).unwrap();
        assert_eq!(out.matches("nonce=").count(), 1, "{out}");
        assert!(out.contains(r#"nonce="old""#), "{out}");
    }

    #[test]
    fn malformed_markup_is_passed_through_rather_than_dropped() {
        let html = b"<script no close";
        let out = nonce_into(html.to_vec(), "abc");
        assert_eq!(out, html, "a truncated tag must not swallow the document");
        assert_eq!(nonce_into(b"plain text".to_vec(), "abc"), b"plain text");
    }

    #[test]
    fn both_policies_forbid_framing_and_never_grant_unsafe_inline_script() {
        for policy in [ADMIN_CSP, &format!("{THEME_CSP_PREFIX}n{THEME_CSP_SUFFIX}")] {
            assert!(policy.contains("frame-ancestors 'none'"), "{policy}");
            assert!(!policy.contains("script-src 'unsafe-inline'"), "{policy}");
            assert!(policy.contains("object-src 'none'"), "{policy}");
        }
        assert!(ADMIN_CSP.contains("script-src 'self'"), "the panel ships no inline script");
        assert!(THEME_CSP_PREFIX.contains("'nonce-"), "the public page admits its nonce only");
    }

    #[test]
    fn hardening_attaches_every_common_header_and_the_policy() {
        let response = harden_admin(StatusCode::OK.into_response());
        let headers = response.headers();
        assert_eq!(headers["x-content-type-options"], "nosniff");
        assert_eq!(headers["x-frame-options"], "DENY");
        assert!(headers.contains_key(header::CONTENT_SECURITY_POLICY));

        let response = harden_theme(StatusCode::OK.into_response(), "n1");
        assert!(response.headers()[header::CONTENT_SECURITY_POLICY].to_str().unwrap().contains("'nonce-n1'"));
    }
}
