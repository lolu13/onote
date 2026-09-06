//! Clipboard image support: limits mirrored from `src/imageLimits.ts`, header-only
//! dimension parsing (no decoder in the helper) and a small base64 encoder.

pub const MAX_IMAGE_FILE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_IMAGE_DIMENSION: u32 = 8_192;
pub const MAX_IMAGE_PIXELS: u64 = 16_000_000;
pub const MAX_IMAGES_PER_NOTE: usize = 20;

/// Preferred order when the clipboard offers several. Only formats whose
/// header this file can read: an image the guard cannot measure is refused.
pub const SUPPORTED: [&str; 3] = ["image/png", "image/jpeg", "image/gif"];

pub fn check_dimensions(w: u32, h: u32) -> Result<(), String> {
    if w == 0 || h == 0 {
        return Err("Image has no size".into());
    }
    if w > MAX_IMAGE_DIMENSION || h > MAX_IMAGE_DIMENSION {
        return Err(format!("Image is larger than {MAX_IMAGE_DIMENSION} px on a side"));
    }
    if u64::from(w) * u64::from(h) > MAX_IMAGE_PIXELS {
        return Err("Image has more than 16 megapixels".into());
    }
    Ok(())
}

/// Width and height from the file header, when the format is one we can read.
pub fn dimensions(mime: &str, bytes: &[u8]) -> Option<(u32, u32)> {
    match mime {
        "image/png" => png(bytes),
        "image/jpeg" => jpeg(bytes),
        "image/gif" => gif(bytes),
        _ => None,
    }
}

fn be32(b: &[u8]) -> u32 { u32::from_be_bytes([b[0], b[1], b[2], b[3]]) }
fn be16(b: &[u8]) -> u32 { u32::from(u16::from_be_bytes([b[0], b[1]])) }

fn png(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 24 || &b[..8] != b"\x89PNG\r\n\x1a\n" || &b[12..16] != b"IHDR" {
        return None;
    }
    Some((be32(&b[16..20]), be32(&b[20..24])))
}

fn gif(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 10 || (&b[..6] != b"GIF89a" && &b[..6] != b"GIF87a") {
        return None;
    }
    Some((u32::from(u16::from_le_bytes([b[6], b[7]])), u32::from(u16::from_le_bytes([b[8], b[9]]))))
}

/// Walks the JPEG segments to the first start-of-frame marker.
fn jpeg(b: &[u8]) -> Option<(u32, u32)> {
    if b.len() < 4 || b[0] != 0xFF || b[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    while i + 9 <= b.len() {
        if b[i] != 0xFF {
            return None;
        }
        let marker = b[i + 1];
        if marker == 0xFF {
            i += 1;
            continue;
        }
        let sof = matches!(marker, 0xC0..=0xCF) && !matches!(marker, 0xC4 | 0xC8 | 0xCC);
        if sof {
            return Some((be16(&b[i + 7..i + 9]), be16(&b[i + 5..i + 7])));
        }
        let len = be16(&b[i + 2..i + 4]) as usize;
        if len < 2 {
            return None;
        }
        i += 2 + len;
    }
    None
}

pub fn base64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((bytes.len() + 2) / 3 * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_matches_known_vectors() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"M"), "TQ==");
        assert_eq!(base64(b"Ma"), "TWE=");
        assert_eq!(base64(b"Man"), "TWFu");
        assert_eq!(base64(&[0xFF, 0xEE, 0xDD, 0x00]), "/+7dAA==");
    }

    #[test]
    fn header_dimensions_for_png_gif_jpeg() {
        let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
        png.extend_from_slice(&640u32.to_be_bytes());
        png.extend_from_slice(&480u32.to_be_bytes());
        assert_eq!(dimensions("image/png", &png), Some((640, 480)));
        assert_eq!(dimensions("image/png", b"not a png"), None);

        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&300u16.to_le_bytes());
        gif.extend_from_slice(&200u16.to_le_bytes());
        assert_eq!(dimensions("image/gif", &gif), Some((300, 200)));

        // SOI, APP0 segment (length 4), then SOF0 with height 1080 width 1920.
        let mut jpg = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46];
        jpg.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x11, 0x08]);
        jpg.extend_from_slice(&1080u16.to_be_bytes());
        jpg.extend_from_slice(&1920u16.to_be_bytes());
        jpg.extend_from_slice(&[0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        assert_eq!(dimensions("image/jpeg", &jpg), Some((1920, 1080)));
        assert_eq!(dimensions("image/webp", b"RIFF....WEBP"), None, "unknown formats have no dimensions and are refused");
        assert!(!SUPPORTED.contains(&"image/webp"));
    }

    #[test]
    fn dimension_limits() {
        assert!(check_dimensions(8192, 1953).is_ok());
        assert!(check_dimensions(8193, 10).unwrap_err().contains("8192"));
        assert!(check_dimensions(4000, 4001).unwrap_err().contains("megapixels"));
        assert!(check_dimensions(0, 10).is_err());
    }
}
