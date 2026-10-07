//! Bounded-memory serving for external theme files, including video ranges.
use axum::{
    body::Body,
    http::{header, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Response},
};
use std::path::Path;
use tokio::io::{AsyncReadExt, AsyncSeekExt};

fn byte_range(value: &str, len: u64) -> Result<Option<(u64, u64)>, ()> {
    let Some(value) = value.strip_prefix("bytes=") else {
        return Ok(None);
    };
    if value.contains(',') {
        return Ok(None);
    } // Multipart ranges are optional.
    let (start, end) = value.split_once('-').ok_or(())?;
    if len == 0 {
        return Err(());
    }
    if start.is_empty() {
        let suffix: u64 = end.parse().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        return Ok(Some((len.saturating_sub(suffix), len - 1)));
    }
    let start: u64 = start.parse().map_err(|_| ())?;
    let end = if end.is_empty() { len - 1 } else { end.parse::<u64>().map_err(|_| ())?.min(len - 1) };
    if start >= len || end < start {
        return Err(());
    }
    Ok(Some((start, end)))
}

pub async fn serve(root: &Path, requested: &str, headers: &HeaderMap, method: &Method) -> Option<Response> {
    let root = tokio::fs::canonicalize(root).await.ok()?;
    let path = tokio::fs::canonicalize(root.join(requested)).await.ok()?;
    if !path.starts_with(&root) {
        return None;
    }
    let mut file = tokio::fs::File::open(&path).await.ok()?;
    let metadata = file.metadata().await.ok()?;
    if !metadata.is_file() {
        return None;
    }
    let len = metadata.len();
    let modified = metadata.modified().ok()?;
    let stamp = modified.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
    #[cfg(unix)]
    let identity = {
        use std::os::unix::fs::MetadataExt;
        metadata.ino()
    };
    #[cfg(not(unix))]
    let identity = 0u64;
    let etag = format!("W/\"{identity:x}-{len:x}-{stamp:x}\"");
    let last_modified =
        chrono::DateTime::<chrono::Utc>::from(modified).format("%a, %d %b %Y %H:%M:%S GMT").to_string();
    let mut out = HeaderMap::new();
    out.insert(
        header::CONTENT_TYPE,
        mime_guess::from_path(path).first_or_octet_stream().as_ref().parse().ok()?,
    );
    out.insert(header::CACHE_CONTROL, "no-cache".parse().ok()?);
    out.insert(header::ETAG, etag.parse().ok()?);
    out.insert(header::LAST_MODIFIED, last_modified.parse().ok()?);
    out.insert(header::ACCEPT_RANGES, "bytes".parse().ok()?);
    if headers.get(header::IF_NONE_MATCH).and_then(|v| v.to_str().ok()).is_some_and(|v| v == etag || v == "*")
    {
        return Some((StatusCode::NOT_MODIFIED, out, Body::empty()).into_response());
    }
    let can_range = headers.get(header::IF_RANGE).is_none_or(|v| {
        v.to_str()
            .ok()
            .and_then(|v| chrono::DateTime::parse_from_rfc2822(v).ok())
            .is_some_and(|at| chrono::DateTime::<chrono::Utc>::from(modified).timestamp() <= at.timestamp())
    });
    let range = if can_range && method == Method::GET {
        headers.get(header::RANGE).and_then(|v| v.to_str().ok()).map(|v| byte_range(v, len)).transpose()
    } else {
        Ok(None)
    };
    let (status, start, count) = match range {
        Ok(Some(Some((start, end)))) => {
            out.insert(header::CONTENT_RANGE, format!("bytes {start}-{end}/{len}").parse().ok()?);
            (StatusCode::PARTIAL_CONTENT, start, end - start + 1)
        }
        Ok(_) => (StatusCode::OK, 0, len),
        Err(()) => {
            out.insert(header::CONTENT_RANGE, format!("bytes */{len}").parse().ok()?);
            return Some((StatusCode::RANGE_NOT_SATISFIABLE, out, Body::empty()).into_response());
        }
    };
    out.insert(header::CONTENT_LENGTH, count.to_string().parse().ok()?);
    if method == Method::HEAD {
        return Some((status, out, Body::empty()).into_response());
    }
    file.seek(std::io::SeekFrom::Start(start)).await.ok()?;
    let stream = tokio_util::io::ReaderStream::with_capacity(file.take(count), 32 * 1024);
    Some((status, out, Body::from_stream(stream)).into_response())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranges_are_bounded_by_the_file() {
        assert_eq!(byte_range("bytes=2-4", 10), Ok(Some((2, 4))));
        assert_eq!(byte_range("bytes=-3", 10), Ok(Some((7, 9))));
        assert_eq!(byte_range("bytes=5-100", 10), Ok(Some((5, 9))));
        assert_eq!(byte_range("bytes=11-", 10), Err(()));
        assert_eq!(byte_range("bytes=0-", 0), Err(()));
    }
    #[tokio::test]
    async fn video_is_streamed_with_range_head_and_revalidation() {
        let dir = std::env::temp_dir().join(format!(
            "monitor-assets-{}-{}",
            std::process::id(),
            crate::auth::random_token()
        ));
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("video.mp4"), b"0123456789").unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, "bytes=2-4".parse().unwrap());
        let response = serve(&dir, "video.mp4", &headers, &Method::GET).await.unwrap();
        assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
        assert_eq!(response.headers()[header::CONTENT_RANGE], "bytes 2-4/10");
        assert_eq!(axum::body::to_bytes(response.into_body(), 16).await.unwrap().as_ref(), b"234");
        let response = serve(&dir, "video.mp4", &HeaderMap::new(), &Method::HEAD).await.unwrap();
        assert_eq!(response.headers()[header::CONTENT_LENGTH], "10");
        assert!(axum::body::to_bytes(response.into_body(), 16).await.unwrap().is_empty());
        let response = serve(&dir, "video.mp4", &HeaderMap::new(), &Method::GET).await.unwrap();
        assert_eq!(response.headers()[header::CACHE_CONTROL], "no-cache");
        headers = HeaderMap::new();
        headers.insert(header::IF_NONE_MATCH, response.headers()[header::ETAG].clone());
        assert_eq!(
            serve(&dir, "video.mp4", &headers, &Method::GET).await.unwrap().status(),
            StatusCode::NOT_MODIFIED
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
